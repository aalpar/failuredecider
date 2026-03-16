# Don't Let Your System Decide It's Dead

Distributed systems fail in two ways: the failure itself, and the system's automatic response to the failure. The second is often worse.

The root cause is systems making semantic decisions with insufficient information — promoting "slow" to "dead" based on wall-clock constants rather than measured resource models. There's a precise invariant that separates safe automatic recovery from cascading failure, and a design principle that tells you who should make which decisions. Most production systems violate both.

---

## The Setup: A Configuration Parameter That Eats Your Data

Cassandra has a setting called `gc_grace_seconds`. It defaults to 864,000 — ten days. Here's what it does: when you delete a row, Cassandra doesn't remove it. It writes a tombstone — a marker that says "this key was deleted." Tombstones exist because in an eventually consistent system, if you just remove the data, another replica that hasn't heard about the deletion will happily replicate the old value back. The tombstone is the deletion's proof of existence.

`gc_grace_seconds` is how long Cassandra keeps that proof around. After ten days, Cassandra garbage-collects the tombstone. The assumption: repair has propagated the tombstone to all replicas within that window.

If repair didn't run — or didn't finish — within those ten days, the tombstone disappears from some replicas while the pre-delete value still exists on others. The deleted data silently reappears. This is a well-documented production failure mode.

What just happened? A single wall-clock constant made two different decisions simultaneously:

1. **A local decision**: "This tombstone's storage can be reclaimed." (Garbage collection — the system has the information to do this.)
2. **A semantic decision**: "All replicas have observed this deletion." (Replication state — the system is *guessing*.)

These are different decisions requiring different information. Conflating them is the root of most cascading failures in distributed systems, and the pattern repeats everywhere: timeouts that promote "slow" to "dead," OOM killers that choose which process to sacrifice, swap systems that silently trade memory bandwidth for disk bandwidth until everything grinds to a halt.

This article is about drawing the line correctly.

---

## The Two Decisions

Every failure in a distributed system requires two decisions:

1. **The local decision**: "This connection/request/operation has failed."
2. **The semantic decision**: "This node/peer/service is gone and I should act accordingly."

The first is a statement about what the system has observed. The second is an interpretation of what that observation *means*. They require different information, are made at different layers, and have different consequences when wrong.

Getting the local decision wrong is usually cheap — a spurious timeout, a wasted retry. Getting the semantic decision wrong can be catastrophic — deleted data resurrected, a healthy node declared dead and its traffic redistributed into an already-overloaded cluster, a cascade that turns a minor hiccup into a major outage.

The engineering challenge is that the semantic decision is *tempting* to automate. Manual intervention is slow. Operators are expensive. And most of the time, the guess is right — the node really is dead, repair really did finish, the process really was misbehaving. Systems are designed for the common case, and the common case makes automation look safe. The failure modes live in the gap between "usually right" and "always right."

---

## TCP Got This Right (Mostly)

TCP's retransmission timeout is the gold standard for automatic failure decisions. It gets nearly everything right, and examining *why* reveals the principles that other systems violate.

**Derived from measurement, not magic constants.** TCP's retransmission timeout (RTO) is computed from Jacobson's round-trip time (RTT) estimator — a smoothed average plus variance of measured round-trip times. The timeout tracks actual network behavior, not an engineer's guess about what it should be.

**Individual recovery cost is bounded and known.** A single retransmission costs one segment — fixed, known in advance, expressed in the same units as normal operation.

**Recovery never amplifies the failure.** Exponential backoff ensures the retry *rate* converges to zero. Each successive timeout doubles the wait. The more congested the network, the less recovery traffic TCP adds to it.

**Failure is surfaced, not hidden.** When TCP exhausts its retries, the application gets `ETIMEDOUT`. TCP doesn't guess what the timeout *means* — it tells the application "this connection is dead" and lets the application decide whether to reconnect, try a different server, or alert an operator.

TCP separates the layers cleanly:

- **TCP decides**: "This connection is dead." (It has the information: measured RTT, retry history, bounded retransmission cost.)
- **Application decides**: "What does this dead connection mean?" (It has the context: service topology, redundancy, retry policy.)
- **Neither decides**: "This node is permanently gone." (This requires physical-world knowledge — hardware state, operator intent — that no software layer has.)

There's a nuance most people miss: TCP *does* eventually give up automatically. `tcp_retries2` defaults to 15 retries, which works out to roughly 13–30 minutes depending on measured RTT. This is a wall-clock timeout, but grounded in a measured resource model — derived from observed network behavior, not pulled from thin air.

<details>
<summary><b>Why this separation is provably necessary (FLP, Chandra-Toueg)</b></summary>

### The impossibility result

The FLP impossibility result (Fischer, Lynch, Paterson, 1985) proves that in an asynchronous system where at least one process may crash, no deterministic algorithm can guarantee consensus. The load-bearing assumption is *asynchrony*: with no bound on message delay or processing time, you cannot distinguish a crashed process from a slow one.

TCP operates *within* the bounds where this distinction is tractable — it measures RTT, so it has a probabilistic model of "how slow is normal." But the question "is this node permanently gone?" lives in the asynchronous regime where FLP applies. No amount of measurement resolves it, because the relevant information (hardware failure, network partition, operator intent) is outside the system's observation boundary.

This is the theoretical foundation for the rest of the argument: systems that promote "slow" to "dead" automatically aren't just making a bad engineering choice — they're making a decision that is *provably underdetermined* by the information available to them. The correct response is the one TCP models: decide what you can (connection liveness), surface what you can't (`ETIMEDOUT`), and let the layer with more information make the semantic call.

### The workaround

Chandra and Toueg (1996) formalized the workaround: you can solve consensus if you have a *failure detector* with known properties (completeness and accuracy). Different detector strengths enable different guarantees. This maps directly to the layered model above — each layer is a failure detector with a specific information boundary, and the system's correctness depends on no layer exceeding its boundary.

</details>

---

## The Recovery Invariant

TCP's design isn't just good engineering intuition — it satisfies a precise invariant that separates safe automatic recovery from cascading failure. The invariant has three levels. Each is necessary; only all three together are sufficient.

### Precondition: You Need a Resource Model

Before evaluating any level, the system must answer a basic question: *recovery costs what, measured in what units, against what capacity?*

The system must name its bottleneck resource, measure its total capacity, and express both normal operations and recovery actions in the same units against that capacity.

TCP has an explicit resource model: bandwidth, measured in segments per round-trip. One normal packet and one retransmission cost the same unit — one segment — against a known link capacity.

Cassandra's hinted handoff has a partial model: one hint replay costs roughly one write in I/O operations per second (IOPS). But the available IOPS during replay depend on concurrent read load, compaction, and repair — variables the hint replay system doesn't observe.

The OOM killer has almost no resource model: it knows system-wide memory pressure triggered the kill, but the cost of killing a specific process (how much memory is freed, how long until the supervisor restarts it, what the restart will allocate) depends on external state the kernel doesn't track.

The precondition is what separates systems that *can* reason about recovery cost from those that act and hope.

<details>
<summary><b>Formal framework: bandwidth as primitive, multi-resource model</b></summary>

### Bandwidth as primitive

Every system resource has a consumption rate expressible as bandwidth: **units of resource per unit time**.

| Resource | Bandwidth unit |
|----------|---------------|
| Network | bytes/sec or segments/RTT |
| Disk I/O | IOPS or bytes/sec |
| CPU | utilization (dimensionless rate) |
| Memory | pages/sec (fault-in rate) |

For pure-flow resources (network, CPU), bandwidth is the resource. There is no at-rest state — a CPU cycle is consumed or not, a packet is in flight or not.

For stock resources (memory capacity, disk space), the at-rest state is the integral of past bandwidth:

> **S(t) = ∫₀ᵗ b_net(τ) dτ**

where b_net is the net consumption rate (allocation rate minus free rate). Every physical memory page was populated through a page fault — zero-fill or disk read — that consumed memory bus bandwidth and potentially disk bandwidth. Virtual address space can be reserved without bandwidth (malloc with overcommit returns immediately), but physical resource consumption always goes through bandwidth.

This unification matters: the recovery invariant constrains rates. Stocks enter only as boundary conditions on accumulated rates.

### Multi-resource model

A system has *n* resources. At time *t*:

- **Cᵢ**: capacity of resource *i* (bandwidth ceiling, in unitsᵢ/sec)
- **wᵢ(t)**: bandwidth consumed by normal operations on resource *i*
- **rᵢ(t)**: bandwidth consumed by recovery actions on resource *i*
- **hᵢ(t) = Cᵢ − wᵢ(t) − rᵢ(t)**: headroom on resource *i*

These form vectors **C**, **w**(t), **r**(t), **h**(t) ∈ ℝⁿ. For stock resources, an additional integral constraint applies:

> **∫₀ᵗ bᵢ_net(τ) dτ ≤ Sᵢ**

Recovery is safe when both conditions hold on every resource:

1. **hᵢ(t) ≥ 0** at all *t* (bandwidth not exceeded)
2. **∫₀ᵗ bᵢ_net(τ) dτ ≤ Sᵢ** for stock resources (capacity not exhausted)

The bottleneck is whichever resource hits either constraint first. It is emergent, not fixed — recovery actions can shift the bottleneck from one resource to another.

</details>

### Level 1: Individual Bound

> Each recovery action's resource cost must be bounded and known.

This is the weakest condition. You must know what a single compensating action costs before you trigger it.

TCP satisfies this: one retransmission costs one segment — fixed, known, independent of system state. Cassandra's hinted handoff satisfies this too: one hint replay costs approximately one write. The OOM killer satisfies this: one kill frees the memory of one process.

Every system I'll discuss passes level 1. That's why it's insufficient. A system can have individually cheap recovery actions and still cascade — the danger is in their aggregate behavior.

### Level 2: Aggregate Bound

> At any point in time, the rate of resource consumption by all concurrent recovery actions must remain below the rate of resource freed by the failures they compensate for.

This is the burst dimension. The distinction between "amortized OK" and "worst-case catastrophic" lives here.

TCP satisfies this: exponential backoff ensures the *rate* of retransmissions decreases with each round, so aggregate retry bandwidth shrinks over time. Google's SRE retry budget is an explicit level-2 mechanism — capping retries at 10% of total requests bounds the aggregate cost to 1.1x normal load regardless of failure count.

Cassandra's hinted handoff violates this: hints accumulate linearly during a node's absence and replay in a burst on return. A 10-minute outage at 100 Mbps per node produces ~7 GiB of hints; at the default 1024 kbps throttle, replay takes ~2 hours. If the throttle is raised (as operators under pressure often do), the burst can recreate the overload that caused the original failure.

### Level 3: Feedback Bound

> Recovery actions must not create conditions that trigger further failures. Equivalently: the recovery feedback loop must have gain < 1.

Levels 1 and 2 treat recovery actions as independent events. Level 3 asks whether they interact. A system violates level 3 when recovery actions consume the same resources that are under contention, creating a positive feedback loop: failure → recovery → more contention → more failure.

TCP satisfies this: backoff *reduces* congestion on the link, which reduces the condition (congestion) that caused the timeout in the first place. The feedback loop is damped — each iteration moves the system closer to equilibrium, not further.

The OOM killer can violate this: a process supervisor restarts the killed process, which allocates memory, which recreates the pressure that triggered the kill. The feedback loop gain depends on external configuration (supervisor policy) that the kernel doesn't know about — another instance of a system making decisions outside its information boundary.

Cassandra's hinted handoff can violate this: burst replay causes CPU/IO contention → read latencies spike → read timeouts trigger read repairs → read repairs consume more CPU/IO → more timeouts. The recovery action for writes triggers a cascade in the read path.

**The decompensation cascade** is what level 3 violation looks like in practice:

1. System overloaded → operations slow down
2. Timeouts fire → compensating actions triggered
3. Compensating actions consume the bottleneck resource → more contention
4. More timeouts → more compensating actions → feedback gain ≥ 1 → cascade

Systems designed for "graceful degradation" often degrade ungracefully because the compensating actions were designed for the steady-state cost model (level 1 holds, level 2 holds at low utilization), not the failure cost model (level 2 breaks under burst, level 3 breaks under sustained pressure). David Woods calls this *decompensation* — the exhaustion of adaptive capacity when the system's own recovery mechanisms become the dominant source of load.

The metastable failures literature (Bronson et al. 2021, Huang et al. 2022) identifies the same phenomenon: "the root cause of a metastable failure is the sustaining feedback loop, rather than the trigger." Their taxonomy of triggers (load-spiking vs capacity-decreasing) and amplification mechanisms (workload amplification vs capacity degradation) maps directly onto levels 2 and 3 of this invariant. The formalization below approaches the same problem from a different mathematical tradition — control theory and linear algebra rather than Markov chains and queuing theory.

### Summary

| Level | Condition | TCP | Hinted handoff | OOM killer |
|-------|-----------|-----|----------------|------------|
| 0. Resource model | Cᵢ, wᵢ(t), rᵢ(t) in shared bandwidth units | ✓ segments on a link | ✗ partial: IOPS but not concurrent load | ✗ memory freed unknown until kill |
| 1. Individual | Cost of one action bounded and known | ✓ one segment | ✓ one write | ✓ one kill |
| 2. Aggregate | Recovery rate ≤ freed capacity | ✓ exponential backoff | ✗ burst on return | ✓ single kill |
| 3. Feedback | Recovery feedback gain < 1 | ✓ backoff reduces congestion | ✗ replay triggers read repair cascade | ✗ supervisor restarts killed process |

<details>
<summary><b>The gain matrix: formalizing the feedback bound</b></summary>

### The gain matrix

Define the *n × n* recovery gain matrix **G**:

> **Gᵢⱼ = ∂rᵢ / ∂(−hⱼ)**

Entry Gᵢⱼ measures how much additional recovery bandwidth appears on resource *i* when headroom on resource *j* decreases by one unit. For systems without backoff, Gᵢⱼ ≥ 0: less headroom means equal or greater recovery demand.

When headroom drops by |Δ**h**|, recovery demand increases by G·|Δ**h**|, reducing headroom further:

> |Δ**h**| → G·|Δ**h**| → G²·|Δ**h**| → ⋯
>
> Total: (I + G + G² + ⋯)·|Δ**h**| = (I − G)⁻¹·|Δ**h**|

This geometric series converges if and only if **ρ(G) < 1**, where ρ(G) is the spectral radius of G (the largest absolute value among its eigenvalues).

> **Stability condition: ρ(G) < 1.**

For a single resource, G is scalar and the condition reduces to G < 1. For multiple resources, the spectral radius captures cross-resource feedback: even if each diagonal entry Gᵢᵢ < 1, the system cascades when off-diagonal entries are large enough — G₁₂ · G₂₁ ≥ 1 means resource 1's recovery stresses resource 2, whose recovery stresses resource 1.

### Monotonicity of the stability boundary

For systems with G ≥ 0, the stability boundary is monotone in load. This follows from a classical result.

**Theorem (Perron-Frobenius, non-negative case).** Let A ∈ ℝⁿˣⁿ with aᵢⱼ ≥ 0 for all i, j. Then:

1. ρ(A) is an eigenvalue of A.
2. There exists x ≥ 0, x ≠ 0, with Ax = ρ(A)x.
3. If B ≥ A entrywise (bᵢⱼ ≥ aᵢⱼ for all i, j), then ρ(B) ≥ ρ(A).

*Proof of property 3.* The Collatz-Wielandt characterization gives ρ(A) = max_{x > 0} min_i (Ax)_i / x_i. If B ≥ A entrywise, then (Bx)_i ≥ (Ax)_i for every x > 0; the inner minimum can only increase, so the outer maximum can only increase. ∎

**Consequence.** If load increase causes any Gᵢⱼ to grow, ρ(G) grows. There exists a critical headroom **h\*** where ρ(G(h\*)) = 1:

- h(t) > h\*: ρ(G) < 1 → stable
- h(t) < h\*: ρ(G) > 1 → cascade

The transition is one-directional. The system cannot self-rescue by becoming more overloaded.

</details>

<details>
<summary><b>Computing h*: UNIX swap thrashing</b></summary>

### Computing h\*: UNIX swap

Swap crosses resource domains — it trades memory capacity (stock) for disk bandwidth (flow) — making it a clean test of the multi-resource framework.

| Symbol | Meaning | Unit |
|--------|---------|------|
| S | Physical memory | pages |
| W | Total working set (all processes) | pages |
| E = W − S | Excess (pages that must swap) | pages |
| f | Distinct page access rate (all processes) | pages/sec |
| D' | Spare disk IOPS (total minus normal workload) | IOPS |

Under uniform access, the probability of hitting a swapped-out page is E/W. Each fault costs 2 IOPS (swap-in read + swap-out write):

> **P = 2f · E / W**

Setting P = D' (disk saturation) and solving for the critical excess:

> **E\* = D' · W / (2f)**

For W ≈ S, the swap margin ratio — excess as a fraction of physical memory:

> **E\*/S = D' / (2f)**

Computed for a 64 GB server (S = 16M pages at 4 KB/page):

| Workload | f (pages/sec) | HDD (D' = 100) | NVMe (D' = 50,000) |
|----------|---------------|-----------------|---------------------|
| Light web (1K req/s) | 10,000 | 320 MB (0.5%) | no h\*† |
| Database (1K qps) | 100,000 | 32 MB (0.05%) | 16 GB (25%) |
| Analytics scan | 1,000,000 | 3.2 MB (0.005%) | 1.6 GB (2.5%) |

† E\*/S > 1: disk bandwidth exceeds maximum possible fault rate. The binding constraint shifts to latency (~100 μs per NVMe fault), which the bandwidth model does not capture.

On a database server with HDD, the system thrashes at 32 MB of excess working set — 0.05% over physical memory. On NVMe, 16 GB. The 500x IOPS improvement buys a proportional increase in margin, but the margin is finite and unmonitored.

**Gain matrix at h\*.** At disk saturation, the feedback loop:

```
G = [[ε,  β],     (disk)
     [α,  ε]]     (memory)
```

- α = ∂(swap IOPS) / ∂(−h_mem) ≈ 2f/W: each page of excess generates 2f/W IOPS
- β = ∂(mem demand) / ∂(−h_disk): disk saturation blocks processes, which hold pages plus ~8–16 KB of kernel I/O buffers per pending operation

Eigenvalues: ε ± √(αβ). Cascade when **αβ ≥ 1** — the cross-resource loop (memory pressure → swap → disk saturation → blocked processes → memory pressure) has compound gain ≥ 1.

</details>

<details>
<summary><b>Computing h*: TCP (the degenerate case)</b></summary>

### Computing h\*: TCP

TCP is the degenerate case: single resource (link bandwidth), scalar gain.

After *k* consecutive timeouts, RTO doubles: RTO_k = RTO_base × 2^k. Retransmission rate:

> **r_k = 1 / (RTO_base × 2^k)**

When congestion increases (h decreases, another round of losses), k increments:

> **r_{k+1} = r_k / 2**

**G_TCP = −0.5.** Each unit of congestion halves recovery demand.

Perron-Frobenius does not apply — G has a negative entry. ρ(|G|) = 0.5 < 1 at all loads. No h\* exists. TCP is unconditionally stable, not because recovery is bounded, but because it is a **contraction**: recovery reduces the condition that triggered it.

| | G ≥ 0 (no backoff) | G < 0 (backoff) |
|---|---|---|
| ρ(G) monotone in load | Non-decreasing | Can decrease |
| h\* exists | Always | May not |
| Self-rescue under overload | Impossible | Possible |

</details>

<details>
<summary><b>Note on nonlinearity (Hartman-Grobman, Lyapunov, cooperative systems)</b></summary>

### Note on nonlinearity

The gain matrix G is the Jacobian of the recovery dynamics at the current operating point — a local linearization. Three results bound the gap between the linear model and the nonlinear system.

**Local validity.** The Hartman-Grobman theorem (Hartman 1960, Grobman 1959) guarantees that the nonlinear system's local phase portrait is topologically equivalent to the linearization when no eigenvalue of G lies on the unit circle. ρ(G) < 1 implies local asymptotic stability; ρ(G) > 1 implies local instability.

**Monotonicity.** For G ≥ 0, ρ(G) is non-decreasing in every entry (Perron-Frobenius property 3). If recovery becomes relatively more expensive as headroom shrinks — true for every system in this article except TCP — then ρ(G) is non-decreasing in load. The boundary h\* is a clean phase transition: stable on one side, cascade on the other. The nonlinear system may reach instability sooner than the linearization predicts, but it cannot reach stability later. The linear analysis is a lower bound on stability — the safe direction for engineering.

**Quantitative margins.** For exact convergence rates, overshoot, or dynamics near ρ(G) = 1, Lyapunov stability analysis provides the general framework: construct V(x) decreasing along trajectories; existence proves stability, rate of decrease bounds convergence. For the monotone case, the theory of cooperative dynamical systems (Hirsch 1985; Smith, *Monotone Dynamical Systems*, 1995) gives stronger structure: trajectories are ordered, limit sets are equilibria, and the worst-case trajectory is computable by evaluating G at its maximum entries.

</details>

**A note on quiesced recovery.** Some systems sidestep levels 2 and 3 entirely by deferring recovery to a state where no production traffic competes for resources — replaying a write-ahead log on startup before accepting connections, running repair during a maintenance window, or batching reconciliation while the node is offline. When the competing workload is zero, level 2 is trivially satisfied and level 3's feedback loop is broken. This is effectively admission control: the system refuses new work until recovery is complete. The trade-off is availability — the node is down during recovery.

The recovery invariant tells you whether recovery *is* safe. It doesn't tell you whether it will *stay* safe, or what to do when it isn't. A system can satisfy all three levels at current load and violate them minutes later. That question — when to compensate automatically and when to stop and escalate — requires a different concept.

---

## The Compensation Boundary

> **The compensation boundary**[^1] is the point in a system's architecture where it stops surfacing failure to a higher authority and starts acting on it automatically. Below the boundary, errors are reported — the caller decides. Above it, the system compensates silently — no one is asked.

The placement of that boundary determines how the system fails under pressure.

### z/OS: The Boundary Drawn Furthest Out

z/OS draws the compensation boundary furthest out of any system I know. WLM assigns work to service classes with defined goals; when the system can't meet goals, it reports the shortfall rather than silently degrading.[^2] z/OS manages memory through explicit region sizes — exceed yours and the job abends (S878, S80A), surfacing a hard failure to the operator.

XCF heartbeat failure detection declares a member dead (it has the information: heartbeat history, configurable intervals), but doesn't decide what the failure *means* for application-level data — recovery exits handle that decision, and may themselves escalate.[^3] Automation is policy-driven (SA z/OS): an operator authored the rule, every automated action is logged, and when no policy matches, the system escalates rather than guessing.[^4]

The escalation mechanism itself is significant: WTO/WTOR (Write to Operator with Reply) is *synchronous* — on critical decisions, the system issues a message and **waits for the operator to respond** before proceeding. The operator is in the control loop by design — consulted during the decision, not notified afterward.

But z/OS isn't immune. Under system-wide memory pressure, it pages to auxiliary storage silently. SRM — which coexists with WLM as its resource-allocation mechanism — swaps out entire address spaces based on system-wide monitoring (paging rates, UIC values, central storage demand). WLM sets policy goals; SRM decides the mechanics. That separation is itself an example of decision authority tracking information: WLM knows what matters to the workload, SRM knows what's happening to the hardware. But the swap-out is still an automatic decision about who gets to run. The compensation boundary is further out than UNIX's, not absent.

### UNIX: A System at War with Itself

UNIX draws the boundary closer in, and the result is a system with a split personality.

The syscall interface surfaces errors faithfully — `errno`, `ENOSPC`, `ENOMEM` from `fork`, `SIGPIPE`, exit codes. This is the "let the caller decide" philosophy. But the resource management layer behind it hides scarcity, and virtual memory is the clearest example.

When physical memory is exhausted, UNIX pages to disk — a compensating action designed to degrade rather than fail. The capacity model is straightforward: physical RAM plus swap, both measurable in bytes, upper bound known at boot. But the *cost* model is incoherent. The system isn't trading memory for disk *space* (swap is pre-allocated); it's trading memory bandwidth for disk bandwidth. A memory access costs ~100ns; a page fault to an HDD costs ~10ms; to NVMe, ~100μs. The compensating action substitutes a resource that is 1,000–100,000x slower per access, and the only unit that makes both sides commensurable is time — the one unit the system doesn't budget.

Against the recovery invariant: Level 1 holds — one page swap frees one page of physical memory, bounded and known. Level 2 is conditional — it holds while disk I/O remains below saturation, but the system swaps without checking disk bandwidth. Level 3 breaks under pressure: swapping consumes both memory bandwidth (page copies) and disk bandwidth (I/O operations), slowing everything → queues build → more memory allocated to pending work → more swapping. Thrashing is a level 3 violation — the recovery action amplifies the condition it compensated for.

This is a defensible decision within UNIX's information boundary — the kernel knows about memory and disk, and paging is within its operational scope. It makes no semantic guess about the application. But acting within your boundary doesn't guarantee stability. Swap satisfies the invariant at low memory pressure and violates it under high pressure, and the system has no mechanism to predict the transition. The implicit stabilization mechanism is degradation itself: as everything slows, users give up, load drops. This is the *absence* of admission control, not a form of it. The system has no mechanism to *cause* load to decrease; it degrades and hopes.

The OOM killer is where the contradiction becomes explicit. When oversubscription hits the wall, Linux makes an automatic semantic decision with unbounded consequences — it kills a *different* process than the one that caused the pressure, chosen by heuristic (`oom_badness` scoring, primarily by memory footprint). Even the default overcommit mode (mode 0, heuristic) allows this; mode 1 (`vm.overcommit_memory=1`) is starker: `malloc` *always* succeeds regardless of available memory, then the kernel kills processes later when it can't honor the promise. Kubernetes sets mode 1 by default.

The error isn't surfaced — it's deferred until it's unrecoverable. When the OOM killer fires, it logs the kill to the kernel ring buffer and continues — no operator acknowledgment, no pause before acting.

UNIX does have tools that push the boundary outward: disk quotas (`EDQUOT`), ulimits (`SIGXCPU`, `SIGXFSZ`, `EMFILE`), cgroups (scoped OOM, CPU throttling). When configured, these behave like the mainframe model — the system says "no" and surfaces an error. But they're all opt-in. A fresh UNIX system has no disk quotas, generous ulimits, no cgroups. Compare z/OS: you can't submit a job without a region size; WLM service classes are mandatory. The compensation boundary in UNIX is a configuration choice. In z/OS it's a design invariant — the system won't run without it. Under production pressure, opt-in boundaries tend to be the first thing relaxed or forgotten.

### Dynamo-Family Systems: No Boundary at All

Dynamo-family systems (Cassandra, Riak, early DynamoDB) barely have a compensation boundary. Compensating actions are implicit in each subsystem, not centrally authored or auditable. Cassandra's `gc_grace_seconds` promotes "old" to "replicated everywhere" based on a wall-clock constant. Hinted handoff accumulates hints during a node failure and replays them in a burst on return. No escalation path exists — when the automatic decision is wrong, the system has already acted.

### The Pattern

| | Reports failure | Compensates silently | Escalation model | Boundary is structural? |
|---|---|---|---|---|
| z/OS | Abends, WLM goal misses, console messages | Paging under system-wide pressure | Synchronous — WTO/WTOR waits for operator | Yes — can't run without region sizes, WLM |
| UNIX | errno at syscall boundary | VM overcommit, swap, OOM killer | Asynchronous — syslog/dmesg, after the fact | No — quotas/cgroups exist but are opt-in |
| Dynamo-family | Logs (if you're watching) | Everywhere: GC, hinted handoff, read repair | None — no escalation path exists | No — compensation is the design |

As the compensation boundary moves inward, the system's failure modes shift from *recoverable* (operator gets a message, decides what to do) to *unrecoverable* (data silently lost, wrong process killed, cascade already in progress). The key property isn't whether a system automates — z/OS automates extensively — but whether *wrong* automatic decisions are surfaced before their consequences become permanent.

---

## Decision Authority Tracks Information Asymmetry

The design principle that ties the preceding sections together:

> Automatic decisions are safe when the decider has sufficient information to guarantee the recovery invariant. When information is insufficient, the system must surface state to the entity that *can* distinguish — and wait.

| Decider | Has information about | Can safely decide |
|---------|----------------------|-------------------|
| TCP | Measured RTT, retry history, bounded retransmission cost | "This connection is dead" |
| Application | Service topology, redundancy, retry policy | "Retry with a different server" |
| Operator | Physical world, business context, acceptable risk | "This node is permanently gone" |

Each layer can make decisions within its information boundary. No layer should make decisions outside it.[^5]

---

## Applying the Principles: CRDT Tombstone GC

CRDT tombstone garbage collection is a clean test case for these principles, because it forces every question they raise.[^6]

CRDTs track deletions with tombstones — markers that say "this key was deleted at time T." A tombstone can only be GCed when *every* replica has observed the deletion, because removing it prematurely from any replica lets the pre-delete value reappear (the zombie resurrection problem). "Every replica has observed it" requires knowing two things: the group membership, and each member's progress. The first is a semantic fact about the physical world. The second is measurable.

**The slow-vs-dead problem is inescapable here.** A peer stops acknowledging — is it partitioned, overloaded, or decommissioned? This is exactly the FLP regime: no amount of observation from inside the system resolves it. Any system that GCs tombstones automatically must promote "unresponsive" to "gone" — an automatic semantic decision with unbounded consequences (silent data resurrection if wrong).

**Cassandra's approach crosses every boundary.** `gc_grace_seconds` is a wall-clock constant that assumes repair will propagate tombstones within 10 days. This is a semantic decision disguised as a configuration parameter, made automatically by the system with insufficient information. The recovery action — hinted handoff replay on node return — violates the recovery invariant by bursting accumulated writes into an already-stressed cluster.

**What the principles demand instead:**

1. **Separate what the system can measure from what it can't.** The system *can* measure: how many tombstones exist, how old they are, which peers have acknowledged which state, and how far behind each peer is. The system *cannot* determine: whether an unresponsive peer will return.

2. **Surface the measurable; defer the unmeasurable.** The API exposes what the system knows: `TombstoneCount()` reports pressure — how urgently GC is needed. `Status()` reports per-peer replication lag — who is behind and by how much. `BlockedBy(d)` names the specific peers preventing a given deletion from being GCed — the bottleneck, not just the symptom.

3. **Reserve the semantic decision for the entity with sufficient information.** `RemovePeer()` is the only call that declares a node gone. It requires the operator — the one entity that can check whether the hardware is dead, whether the network is partitioned, whether the node is being decommissioned. The system will not make this call on its own.

4. **Make the recovery action satisfy the invariant.** If a removed peer returns, it performs a full state transfer rather than delta replay. The returning node bears the cost of reconciliation, and that cost is bounded by the current state size — it doesn't scale with the duration of absence the way accumulated hints do. The cluster doesn't experience a burst.

The result is a compensation boundary drawn where the information boundary actually is: the system compensates for things it can measure (replication lag, tombstone pressure) and surfaces everything else. No wall-clock constant substitutes for operator judgment. No automatic action has unbounded consequences.

---

## Design Rules

1. **Separate local decisions from semantic decisions.** TCP can kill a connection; only an operator can kill a node.

2. **Derive timeouts from measured properties.** If you can't measure it, you can't timeout on it safely.

3. **Check all three levels of the recovery invariant.** Individual cost bounded (level 1) is necessary but insufficient. Verify that aggregate recovery rate stays within freed capacity (level 2) and that recovery actions avoid amplifying the failure condition (level 3). Level 3 failure is a cascade seed.

4. **Surface state, don't hide it.** When you can't decide safely, expose what you know to whoever can.

5. **Make failure a first-class API.** TCP doesn't hide retransmissions from the application — it surfaces `ETIMEDOUT`. Your system shouldn't hide peer lag from the operator.

6. **Prefer recoverable pessimism over unrecoverable optimism.** A slow operator is recoverable. Silent data loss is not.

---

## Related Work

The phenomenon of recovery actions amplifying failures is well-identified across multiple communities:

**Metastable failures.** Bronson et al. (2021) coined the term and identified the sustaining feedback loop — not the trigger — as the root cause. Huang et al. (OSDI 2022) studied 22 metastable failures across 11 organizations, finding that >50% involved retry storms. Isaacs and Alvaro (HotOS 2025) propose a modeling pipeline for discovering susceptibility at design time. The formal analysis in arXiv:2510.03551 provides a CTMC-based spectral characterization of metastable states. This article approaches the same phenomenon from control theory rather than stochastic processes: the gain matrix asks "does the perturbation converge or diverge?" where CTMCs ask "how long does the system stay trapped?"

**Resilience engineering.** David Woods' concept of *decompensation* — the exhaustion of adaptive capacity when recovery mechanisms become the dominant source of load — captures the qualitative phenomenon that level 3 of the recovery invariant formalizes quantitatively. Woods asks whether the system can extend capacity at all (*graceful extensibility*); the compensation boundary asks *where* the system draws the line between reporting and acting. Related: Woods, "Four concepts for resilience" (2015); "The theory of graceful extensibility" (2018).

**Control theory for computing.** Hellerstein et al., *Feedback Control of Computing Systems* (2004), applied control theory (MIMO, transfer functions, gain, pole placement) to computing systems. Their focus is on designing controllers (admission control, scheduling), not on analyzing when existing recovery mechanisms cascade. The gain matrix formalization in this article uses the same mathematical tradition for a different question.

**Cascading failures in other domains.** Ramirez, Odijk, and Bauso (2023) applied gain matrix + Lyapunov stability analysis to cascading failures in financial networks. The spectral radius stability condition ρ(G) < 1 is the same; the domain and the specific construction of G differ.

**Failure detectors.** Chandra and Toueg (1996) formalized the properties (completeness, accuracy) that failure detectors need to enable consensus, establishing the theoretical foundation for the layered decision authority model.

**Exponential backoff stability.** The formal stability of binary exponential backoff is well-studied. This article uses TCP as a pedagogical reference design — an existence proof that safe automatic recovery is achievable — rather than making new claims about TCP itself.

---

## References

Alvaro, Peter, Rebecca Isaacs, Rupak Majumdar, Kiran-Kumar Muniswamy-Reddy, Mahmoud Salamati, and Sadegh Soudjani. 2025. "Formal Analysis of Metastable Failures in Software Systems." arXiv:2510.03551.

Bronson, Nathan, et al. 2021. "Metastable Failures in Distributed Systems." In *HotOS '21: Workshop on Hot Topics in Operating Systems*.

Chandra, Tushar Deepak, and Sam Toueg. 1996. "Unreliable Failure Detectors for Reliable Distributed Systems." *Journal of the ACM* 43, no. 2: 225–267.

Fischer, Michael J., Nancy A. Lynch, and Michael S. Paterson. 1985. "Impossibility of Distributed Consensus with One Faulty Process." *Journal of the ACM* 32, no. 2: 374–382.

Grobman, D. M. 1959. "Homeomorphisms of Systems of Differential Equations." *Doklady Akademii Nauk SSSR* 128: 880–881.

Hartman, Philip. 1960. "A Lemma in the Theory of Structural Stability of Differential Equations." *Proceedings of the American Mathematical Society* 11: 610–620.

Hellerstein, Joseph L., Yixin Diao, Sujay Parekh, and Dawn M. Tilbury. 2004. *Feedback Control of Computing Systems*. Hoboken, NJ: Wiley.

Hirsch, Morris W. 1985. "Systems of Differential Equations That Are Competitive or Cooperative II: Convergence Almost Everywhere." *SIAM Journal on Mathematical Analysis* 16, no. 3: 423–439.

Huang, Lexiang, et al. 2022. "Metastable Failures in the Wild." In *OSDI '22: 16th USENIX Symposium on Operating Systems Design and Implementation*. USENIX.

Isaacs, Rebecca, Peter Alvaro, Rupak Majumdar, Kiran Reddy, Mahmoud Salamati, and Sadegh Soudjani. 2025. "Analyzing Metastable Failures." In *HotOS '25: Workshop on Hot Topics in Operating Systems*.

Ramirez, Stefanny, Maaike Odijk, and Dario Bauso. 2023. "Cascading Failures: Dynamics, Stability and Control." arXiv:2305.00838.

Smith, Hal L. 1995. *Monotone Dynamical Systems: An Introduction to the Theory of Competitive and Cooperative Systems*. Mathematical Surveys and Monographs 41. Providence, RI: American Mathematical Society.

Woods, David D. 2015. "Four Concepts for Resilience and the Implications for the Future of Resilience Engineering." *Reliability Engineering and System Safety* 141: 5–9.

Woods, David D. 2018. "The Theory of Graceful Extensibility: Basic Rules That Govern Adaptive Systems." *Environment Systems and Decisions* 38: 433–457.

---

[^1]: The term *compensating action* originates in transaction processing, where a compensating transaction undoes the effects of a committed transaction that cannot be rolled back (Jim Gray and Andreas Reuter, *Transaction Processing: Concepts and Techniques* (San Mateo, CA: Morgan Kaufmann, 1993)). *Decompensation* — the exhaustion of adaptive capacity when recovery mechanisms become the dominant load source — is David Woods' contribution (see Related Work). The *compensation boundary* as used here — the architectural point where the system stops surfacing failure and starts acting on it — is a framing specific to this article, combining the transactional concept (what is a compensating action?) with the resilience engineering concept (when does compensation become the problem?) and adding the design question: *where should the system draw that line?*

[^2]: WLM (Workload Manager) is the z/OS component that classifies work into service classes with defined performance goals (response time, velocity, discretionary) and dynamically manages system resources — CPU dispatching priority, I/O priority, memory — to meet those goals. When goals cannot be met, WLM reports the shortfall rather than silently degrading. See IBM, *z/OS MVS Planning: Workload Management*, SC34-2662.

[^3]: XCF (Cross-system Coupling Facility) provides group membership, signaling, and heartbeat-based failure detection across z/OS systems within a sysplex. XCF monitors member health via configurable heartbeat intervals and declares a member failed when heartbeats stop — a local decision about connectivity. What that failure *means* for application-level state is delegated to recovery exits registered by the application, not decided by XCF itself. See IBM, *z/OS MVS Setting Up a Sysplex*, SA23-1399.

[^4]: SA z/OS (IBM System Automation for z/OS) is a policy-driven automation framework for z/OS operations. Operators author automation rules that define responses to system events; every automated action is logged and auditable. When no rule matches a condition, SA z/OS escalates to the operator rather than guessing. See IBM, *System Automation for z/OS Planning and Installation*, SC34-2571.

[^5]: DHCP lease expiry faces the same structural problem — "lease expired" is not "address unused" — but largely avoids it through protocol design: the client contractually agrees to stop using the address at expiry, and Duplicate Address Detection (RFC 5227) catches most residual conflicts. The type error exists but the protocol mitigates it bilaterally rather than ignoring it. Contrast Cassandra's `gc_grace_seconds`, where no such mitigation exists — the wall-clock constant is the entire mechanism.

[^6]: CRDT (Conflict-free Replicated Data Type) — a family of data structures that can be replicated across multiple nodes, updated independently and concurrently, and merged deterministically without coordination. The merge function is mathematically guaranteed to converge (it forms a join-semilattice), which eliminates the need for consensus on every write — at the cost of carrying metadata, including tombstones, that can only be safely discarded when all replicas have observed it. See Shapiro, Preguiça, Baquero, Zawirski, "A comprehensive study of Convergent and Commutative Replicated Data Types," INRIA Technical Report RR-7506, 2011.

*Thanks for reading. If you work on distributed systems and have seen the recovery invariant violated in ways not covered here, or if you spot errors in the formalization, I'd like to hear about it.*
