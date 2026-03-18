# Don't Let Your System Decide It's Dead

**Working title.** Alternatives: "The Recovery Invariant", "Why Cassandra's gc_grace_seconds Is a Lie", "Decision Authority and Information Asymmetry in Distributed Systems"

## Thesis

Distributed systems fail in two ways: the failure itself, and the system's automatic response to the failure. The second is often worse. The root cause is systems making semantic decisions with insufficient information — promoting "slow" to "dead" based on wall-clock constants rather than measured resource models.

There's a precise invariant that separates safe automatic recovery from cascading failure, and a design principle that tells you who should make which decisions. Most production systems violate both.

---

## Outline

### 1. The Two Decisions

Every failure in a distributed system requires two decisions:

1. **The local decision**: "This connection/request/operation has failed." (TCP level)
2. **The semantic decision**: "This node/peer/service is gone and I should act accordingly." (Application/operator level)

These are different decisions made by different entities with different information. Conflating them is the root of most cascading failures.

**Example to open with:** Cassandra's `gc_grace_seconds`. A single wall-clock constant that makes both decisions: "if a tombstone is older than 10 days, repair must have propagated it to all replicas, so GC it." If repair didn't run — or didn't finish — within that window, deleted data silently reappears. This is an automatic semantic decision disguised as a configuration parameter.

### 2. TCP Got This Right (Mostly)

TCP's retransmission timeout is the gold standard for automatic failure decisions:

- **Derived from measurement**: Jacobson's RTT estimator + variance, not a magic constant
- **Cost of individual action is bounded**: a single retransmission costs one segment — known and fixed
- **Exponential backoff**: retry *rate* converges to zero — recovery never amplifies the failure
- **Failure is surfaced, not hidden**: application gets ETIMEDOUT, decides what it means

The nuance most people miss: TCP *does* eventually give up automatically (`tcp_retries2`, default 15, ~13–30 minutes). This IS a wall-clock timeout — but one grounded in a measured resource model, not pulled from thin air.

TCP separates the layers cleanly:
- TCP decides: "this connection is dead" (has the information: measured RTT, retry history)
- Application decides: "what does this dead connection mean?" (has the context: topology, redundancy)
- Neither decides: "this node is permanently gone" (requires physical-world knowledge)

**Why this separation is provably necessary.** The FLP impossibility result (Fischer, Lynch, Paterson, 1985) proves that in an asynchronous system where at least one process may crash, no deterministic algorithm can guarantee consensus. The load-bearing assumption is asynchrony: with no bound on message delay or processing time, you cannot distinguish a crashed process from a slow one. TCP operates *within* the bounds where this distinction is tractable — it measures RTT, so it has a probabilistic model of "how slow is normal." But the question "is this node permanently gone?" lives in the asynchronous regime where FLP applies. No amount of measurement resolves it, because the relevant information (hardware failure, network partition, operator intent) is outside the system's observation boundary.

This is the theoretical foundation for the rest of the argument: systems that promote "slow" to "dead" automatically aren't just making a bad engineering choice — they're making a decision that is *provably underdetermined* by the information available to them. The correct response is the one TCP models: decide what you can (connection liveness), surface what you can't (ETIMEDOUT), and let the layer with more information make the semantic call.

Chandra and Toueg (1996) formalized the workaround: you can solve consensus if you have a *failure detector* with known properties (completeness and accuracy). Different detector strengths enable different guarantees. This maps directly to the layered model above — each layer is a failure detector with a specific information boundary, and the system's correctness depends on no layer exceeding its boundary.

### 3. Formal Framework

The claims in the following sections — that recovery actions must be bounded, that aggregate recovery must not exceed freed capacity, that feedback gain must be less than 1 — can be stated precisely. This section provides the mathematical framework; subsequent sections apply it.

#### Bandwidth as Primitive

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

This unification matters: the recovery invariant (section 4) constrains rates. Stocks enter only as boundary conditions on accumulated rates.

#### Multi-Resource Model

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

#### The Gain Matrix

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

#### Monotonicity of the Stability Boundary

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

#### Computing h\*: UNIX Swap

Swap crosses resource domains — it trades memory capacity (stock) for disk bandwidth (flow) — making it a clean test of the multi-resource framework.

| Symbol | Meaning | Unit |
|--------|---------|------|
| S | Physical memory | pages |
| W | Total working set (all processes) | pages |
| E = W − S | Excess (pages that must swap) | pages |
| f | Distinct page access rate (all processes) | pages/sec |
| D' | Spare disk IOPS (total minus normal workload) | IOPS |

Under uniform access, the probability of hitting a swapped-out page is E/W. Real workloads have locality: under the working set model (Denning 1968), fault rate is near-zero while working sets fit in physical memory and spikes when they do not. The uniform assumption smooths this transition, yielding a lower bound on E\* — the true margin is larger, but the failure at the true boundary is sharper than the smooth model depicts. The table values below are conservative estimates of the minimum margin.

Each fault costs 2 IOPS (swap-in read + swap-out write):

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

On a database server with HDD, the system thrashes at 32 MB of excess working set — 0.05% over physical memory. On NVMe, 16 GB. The 500× IOPS improvement buys a proportional increase in margin, but the margin is finite and unmonitored.

**Gain matrix at h\*.** At disk saturation, the feedback loop:

```
G = [[ε,  β],     (disk)
     [α,  ε]]     (memory)
```

- α = ∂(swap IOPS) / ∂(−h_mem) ≈ 2f/W: each page of excess generates 2f/W IOPS
- β = ∂(mem demand) / ∂(−h_disk): disk saturation blocks processes, which hold pages plus ~8–16 KB of kernel I/O buffers per pending operation

Eigenvalues: ε ± √(αβ). Cascade when **αβ ≥ 1** — the cross-resource loop (memory pressure → swap → disk saturation → blocked processes → memory pressure) has compound gain ≥ 1.

#### Computing h\*: TCP

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

#### Computing h\*: Cassandra Hint Replay

Cassandra's cascade is disk-dominated: single resource (disk IOPS), scalar gain with a nonlinear trigger.

During an outage, hints accumulate at the write rate. On return, they replay at a throttled rate R, adding to normal disk load D_n. Disk utilization:

> **u = (D_n + R) / D_t**

Read latency follows the M/M/1 queueing model:

> **L = b / (1 − u)**

where b is the base read latency under no contention. Timeouts occur when L exceeds the read timeout threshold τ:

> **u\* = 1 − b/τ**

At u\*, the feedback loop engages: timeouts trigger read repairs, each costing c_r IOPS, which increase utilization further. The feedback gain, derived via chain rule through the M/M/1 model:

> **g = c_r · r_r · τ / (b · D_t)**

where r_r is the read rate. Below u\*, g = 0 — no timeouts, no feedback. Above u\*, g >> 1 for typical parameters. This is a phase transition, not a smooth crossing: the system jumps from stable to violently unstable at u\*.

The critical headroom — IOPS margin before cascade:

> **h\* = D_t · b / τ**

The safe replay rate — maximum hint replay before crossing u\*:

> **R\* = D_t · (1 − b/τ) − D_n**

| Parameter | Value | |
|-----------|-------|---|
| D_t (disk capacity) | 500 IOPS | |
| D_n (normal load) | 200 IOPS | |
| b (base latency) | 5 ms | |
| τ (read timeout) | 500 ms | |
| c_r (repair cost) | 3 IOPS | |
| r_r (read rate) | 5,000 reads/sec | |
| **u\*** | **0.99** | 99% utilization |
| **h\*** | **5 IOPS** | 1% of disk capacity |
| **R\*** | **295 ops/sec** | safe replay rate |
| **g (above u\*)** | **3,000** | gain above threshold |

At 5 IOPS of headroom — 1% of a 500-IOPS disk — the read repair feedback gain jumps from zero to 3,000. The default Cassandra throttle (128 ops/sec) is safe; raising it to 300 is cascade.

**Structural contrast with swap.** Both h\* values are closed-form functions of measurable quantities. The instability structures differ: swap has a smooth transition (ρ crosses 1 as load increases, linearized h\* is a conservative lower bound). Cassandra has a phase transition (gain jumps from 0 to >> 1 at u\*). The M/M/1 nonlinearity creates a cliff, not a slope. The linearization critique (Hartman-Grobman radius unknown) applies to swap's smooth boundary but not to Cassandra's discontinuous one — the phase transition IS the nonlinearity, computed exactly.

#### Note on Nonlinearity

The gain matrix G is the Jacobian of the recovery dynamics at the current operating point — a local linearization. Three results bound the gap between the linear model and the nonlinear system.

**Local validity.** The Hartman-Grobman theorem (Hartman 1960, Grobman 1959) guarantees that the nonlinear system's local phase portrait is topologically equivalent to the linearization when no eigenvalue of G lies on the unit circle. ρ(G) < 1 implies local asymptotic stability; ρ(G) > 1 implies local instability.

**Monotonicity.** For G ≥ 0, ρ(G) is non-decreasing in every entry (Perron-Frobenius property 3). If recovery becomes relatively more expensive as headroom shrinks — true for every system in this paper except TCP — then ρ(G) is non-decreasing in load. The boundary h\* is a clean phase transition: stable on one side, cascade on the other. The nonlinear system may reach instability sooner than the linearization predicts, but it cannot reach stability later. The linear analysis is a lower bound on stability — the safe direction for engineering.

**Quantitative margins.** For exact convergence rates, overshoot, or dynamics near ρ(G) = 1, Lyapunov stability analysis provides the general framework: construct V(x) decreasing along trajectories; existence proves stability, rate of decrease bounds convergence. For the monotone case, the theory of cooperative dynamical systems (Hirsch 1985; Smith, *Monotone Dynamical Systems*, 1995) gives stronger structure: trajectories are ordered, limit sets are equilibria, and the worst-case trajectory is computable by evaluating G at its maximum entries.

### 4. The Recovery Invariant

For automatic recovery to be safe, it must satisfy three conditions. Each is necessary. When all three hold, recovery converges locally — within the linearization radius of the current operating point. The monotonicity result (Perron-Frobenius, section 3) ensures the computed h\* is a lower bound on the true stability boundary: the framework never declares safety when danger exists, though it may declare danger when safety exists.

#### Precondition: Resource Model

> The system must name its bottleneck resource, measure its total capacity, and express both normal operations and recovery actions in the same units against that capacity.

Without this, the three levels below are not evaluable. "Bounded and known" means nothing if you can't state what the bound is relative to. Section 3 formalizes this: define each resource's capacity Cᵢ, workload wᵢ(t), and recovery rᵢ(t) in shared bandwidth units (resource/time), with headroom hᵢ(t) = Cᵢ − wᵢ(t) − rᵢ(t). TCP has an explicit resource model: bandwidth, measured in segments per round-trip. One normal packet and one retransmission cost the same unit — one segment — against a known link capacity. Cassandra's hinted handoff has a partial model: one hint replay ≈ one write in IOPS, but the available IOPS during replay depend on concurrent read load, compaction, and repair — variables the hint replay system doesn't observe. The OOM killer has almost no resource model: it knows system-wide memory pressure triggered the kill, but the cost of killing a specific process (how much memory is freed, how long until the supervisor restarts it, what the restart will allocate) depends on external state the kernel doesn't track.

The precondition is what separates systems that *can* reason about recovery cost from those that act and hope. The weaker the resource model, the less the three levels below can guarantee.

#### Level 1: Individual Bound

> Each recovery action's resource cost must be bounded and known.

This is the weakest condition. It says you must know what a single compensating action costs before you trigger it — the cost vector **δ**(a) from section 3, specifying bandwidth consumed from each resource by a single recovery action.

TCP satisfies this: one retransmission costs one segment — fixed, known, independent of system state. Cassandra's hinted handoff satisfies this too: one hint replay costs approximately one write. The OOM killer satisfies this: one kill frees the memory of one process.

Every system in this paper passes level 1. That's why it's insufficient — and doubly so for systems without a resource model (precondition), which pass level 1 vacuously: "one kill" is bounded, but bounded in what units against what capacity? A system can have individually cheap recovery actions and still cascade — the danger is in their aggregate behavior.

#### Level 2: Aggregate Bound

> At any point in time, the rate of resource consumption by all concurrent recovery actions must not exceed the rate of resource freed by the failures they compensate for.

This is the burst dimension — formally, **hᵢ(t) ≥ 0** for all resources at all times (section 3). The distinction between "amortized OK" and "worst-case catastrophic" lives here.

TCP satisfies this: exponential backoff ensures the *rate* of retransmissions decreases with each round, so aggregate retry bandwidth shrinks over time. Google's SRE retry budget is an explicit level-2 mechanism — capping retries at 10% of total requests bounds the aggregate cost to 1.1× normal load regardless of failure count.

Cassandra's hinted handoff violates this: hints accumulate linearly during a node's absence and replay in a burst on return. A 10-minute outage at 100 Mbps per node produces ~7 GiB of hints; at the default 1024 kbps throttle, replay takes ~2 hours. If the throttle is raised (as operators under pressure often do), the burst can recreate the overload that caused the original failure.

The resource dimension matters and varies by system: bandwidth for TCP, IOPS and CPU for Cassandra, memory for the OOM killer. The invariant must hold in *the bottleneck resource* — the one that saturates first under load.

#### Level 3: Feedback Bound

> Recovery actions must not create conditions that trigger further failures. Equivalently: the recovery feedback loop must have gain < 1.

This is the cascade condition — formally, **ρ(G) < 1** where G is the recovery gain matrix (section 3). Levels 1 and 2 treat recovery actions as independent events; level 3 asks whether they interact. A system violates level 3 when recovery actions consume the same resources that are under contention, creating a positive feedback loop: failure → recovery → more contention → more failure.

TCP satisfies this: backoff *reduces* congestion on the link, which reduces the condition (congestion) that caused the timeout in the first place. The feedback loop is damped — each iteration moves the system closer to equilibrium, not further.

The OOM killer can violate this: a process supervisor restarts the killed process, which allocates memory, which recreates the pressure that triggered the kill. The feedback loop gain depends on external configuration (supervisor policy) that the kernel doesn't know about — another instance of a system making decisions outside its information boundary.

Cassandra's hinted handoff can violate this: burst replay causes CPU/IO contention → read latencies spike → read timeouts trigger read repairs → read repairs consume more CPU/IO → more timeouts. The recovery action for writes triggers a cascade in the read path.

**The decompensation cascade** is what level 3 violation looks like in practice:

1. System overloaded → operations slow down
2. Timeouts fire → compensating actions triggered
3. Compensating actions consume the bottleneck resource → more contention
4. More timeouts → more compensating actions → feedback gain ≥ 1 → cascade

Systems designed for "graceful degradation" often degrade ungracefully because the compensating actions were designed for the steady-state cost model (level 1 holds, level 2 holds at low utilization), not the failure cost model (level 2 breaks under burst, level 3 breaks under sustained pressure). David Woods calls this *decompensation* — the exhaustion of adaptive capacity when the system's own recovery mechanisms become the dominant source of load.

#### Summary

| Level | Condition | TCP | Hinted handoff | OOM killer |
|-------|-----------|-----|----------------|------------|
| 0. Resource model | Cᵢ, wᵢ(t), rᵢ(t) in shared bandwidth units | ✓ segments on a link | ✗ partial: IOPS but not concurrent load | ✗ memory freed unknown until kill |
| 1. Individual | **δ**(a) bounded and known | ✓ one segment | ✓ one write | ✓ one kill |
| 2. Aggregate | **hᵢ(t) ≥ 0**: recovery rate ≤ freed capacity | ✓ exponential backoff | ✗ burst on return | ✓ single kill |
| 3. Feedback | **ρ(G) < 1**: no cascade | ✓ backoff reduces congestion | ✗ replay triggers read repair cascade | ✗ supervisor restarts killed process |

**A note on quiesced recovery.** Some systems sidestep levels 2 and 3 by deferring recovery to a state where no production traffic competes for resources — replaying a write-ahead log on startup before accepting connections, running repair during a maintenance window, or batching reconciliation while the node is offline. When the competing workload is zero, the aggregate bound (level 2) is trivially satisfied: the entire system's capacity is available for recovery. The feedback loop (level 3) is broken: with no incoming requests, recovery actions can't cascade through the serving path. This is effectively an admission control strategy — the system refuses new work until recovery is complete. The cost equation changes because the denominator drops to near-zero. The trade-off is availability: the node is down (or read-only) during recovery, which may or may not be acceptable depending on the system's consistency and availability requirements.

TCP satisfies the invariant cleanly because its resource model is tight: one resource (link bandwidth), one unit (segments per round-trip), and recovery costs the same unit as normal operation. Most real systems aren't this clean. When a compensating action shifts failures across resource domains — memory pressure compensated by disk I/O, failed writes compensated by queued hints — the single-resource intuition breaks. The multi-resource gain matrix (section 3) captures these cross-resource feedback loops through its off-diagonal entries, and the h\* computation (section 3, UNIX Swap) shows the stability boundary is quantifiable. But the invariant remains conditional on load the system doesn't control.

This is where the recovery invariant stops being sufficient on its own. A system can satisfy all three levels at current load and violate them minutes later. The invariant tells you whether recovery *is* safe — not whether it will *stay* safe, or what to do when it isn't. That question — when to compensate automatically and when to stop and escalate — requires a different concept.

### 5. The Compensation Boundary

> **The compensation boundary**[^1] is the point in a system's architecture where it stops surfacing failure to a higher authority and starts acting on it automatically. Below the boundary, errors are reported — the caller decides. Above it, the system compensates silently — no one is asked.

The placement of that boundary determines how the system fails under pressure.

**z/OS** draws the boundary furthest out. WLM[^2] assigns work to service classes with defined goals; when the system can't meet goals, it reports the shortfall rather than silently degrading. Memory is managed via explicit region sizes — exceed yours and the job abends (S878, S80A), a hard failure surfaced to the operator. XCF[^3] heartbeat failure detection declares a member dead (it has the information: heartbeat history, configurable intervals), but doesn't decide what the failure *means* for application-level data — that's left to recovery exits, which may themselves escalate. Automation is policy-driven (SA z/OS[^4]): an operator authored the rule, every automated action is logged, and when no policy matches, the system escalates rather than guessing. The escalation mechanism itself is significant: WTO/WTOR (Write to Operator with Reply) is *synchronous* — on critical decisions, the system issues a message and **waits for the operator to respond** before proceeding. The operator isn't informed after the fact; they're in the control loop by design.

But z/OS isn't immune. Under system-wide memory pressure, it pages to auxiliary storage silently. SRM — which coexists with WLM as its resource-allocation mechanism, not a predecessor it replaced — swaps out entire address spaces based on system-wide monitoring (paging rates, UIC values, central storage demand). WLM sets policy goals; SRM decides the mechanics. That separation is itself an example of decision authority tracking information: WLM knows what matters to the workload, SRM knows what's happening to the hardware. But the swap-out is still an automatic decision about who gets to run. The compensation boundary is further out than UNIX's, not absent.

**UNIX** draws the boundary closer in, and the result is a system at war with itself. The syscall interface surfaces errors faithfully — errno, ENOSPC, ENOMEM from `fork`, SIGPIPE, exit codes. This is the "let the caller decide" philosophy. But the resource management layer behind it hides scarcity, and virtual memory is the clearest example.

When physical memory is exhausted, UNIX pages to disk — a compensating action designed to degrade rather than fail. The capacity model is straightforward: physical RAM plus swap, both measurable in bytes, upper bound known at boot. But the *cost* model is incoherent. The system isn't trading memory for disk *space* (swap is pre-allocated); it's trading memory bandwidth for disk bandwidth. A memory access costs ~100ns; a page fault to an HDD costs ~10ms; to NVMe, ~100μs. The compensating action substitutes a resource that is 1,000–100,000× slower per access, and the only unit that makes both sides commensurable is time — the one unit the system doesn't budget.

Against the recovery invariant: Level 1 holds — one page swap frees one page of physical memory, bounded and known. Level 2 is conditional — it holds while disk I/O isn't saturated, but the system doesn't check disk bandwidth utilization before swapping. Level 3 is where it breaks under pressure: swapping consumes both memory bandwidth (page copies) and disk bandwidth (I/O operations), slowing everything → queues build → more memory allocated to pending work → more swapping. Thrashing is level 3 violation in this domain — the recovery action amplifies the condition it compensated for.

This is a defensible decision within UNIX's information boundary — the kernel knows about memory and disk, and paging is within its operational scope. It isn't making a semantic guess about the application. But acting within your boundary doesn't guarantee stability. Swap satisfies the invariant at low memory pressure and violates it under high pressure, and the system has no mechanism to predict the transition. The implicit stabilization mechanism is degradation itself: as everything slows, users give up, load drops. But this is the *absence* of admission control, not a form of it. The system has no mechanism to *cause* load to decrease; it degrades and hopes. A system that only stabilizes when external load happens to decrease is conditionally stable — and the condition is outside the system's control.

The OOM killer is where the contradiction becomes explicit. When oversubscription hits the wall, Linux makes an automatic semantic decision with unbounded consequences — it kills a *different* process than the one that caused the pressure, chosen by heuristic (`oom_badness` scoring, primarily by memory footprint). Even the default overcommit mode (mode 0, heuristic) allows this; mode 1 (`vm.overcommit_memory=1`) is starker: `malloc` *always* succeeds regardless of available memory, then the kernel kills processes later when it can't honor the promise. Kubernetes sets mode 1 by default. The error isn't surfaced — it's deferred until it's unrecoverable. When the OOM killer fires, it logs the kill to the kernel ring buffer and continues — no operator acknowledgment, no pause before acting. The operator learns about it from `dmesg` or monitoring, after consequences are already in motion.

UNIX does have tools that push the boundary outward: disk quotas (EDQUOT), ulimits (SIGXCPU, SIGXFSZ, EMFILE), cgroups (scoped OOM, CPU throttling). When configured, these behave like the mainframe model — the system says "no" and surfaces an error. But they're all opt-in. A fresh UNIX system has no disk quotas, generous ulimits, no cgroups. Compare z/OS: you can't submit a job without a region size; WLM service classes are mandatory. The compensation boundary in UNIX is a configuration choice. In z/OS it's a design invariant — the system won't run without it. Under production pressure, opt-in boundaries tend to be the first thing relaxed or forgotten.

**Dynamo-family systems** (Cassandra, Riak, early DynamoDB) barely have a compensation boundary at all. Compensating actions are implicit in each subsystem, not centrally authored or auditable. Cassandra's `gc_grace_seconds` promotes "old" to "replicated everywhere" based on a wall-clock constant. Hinted handoff accumulates hints during a node failure and replays them in a burst on return. No escalation path exists — when the automatic decision is wrong, the system has already acted.

| | Reports failure | Compensates silently | Escalation model | Boundary is structural? |
|---|---|---|---|---|
| z/OS | Abends, WLM goal misses, console messages | Paging under system-wide pressure | Synchronous — WTO/WTOR waits for operator | Yes — can't run without region sizes, WLM |
| UNIX | errno at syscall boundary | VM overcommit, swap, OOM killer | Asynchronous — syslog/dmesg, after the fact | No — quotas/cgroups exist but are opt-in |
| Dynamo-family | Logs (if you're watching) | Everywhere: GC, hinted handoff, read repair | None — no escalation path exists | No — compensation is the design |

The pattern: as the compensation boundary moves inward, the system's failure modes shift from *recoverable* (operator gets a message, decides what to do) to *unrecoverable* (data silently lost, wrong process killed, cascade already in progress). The key property isn't whether a system automates — z/OS automates extensively — but whether *wrong* automatic decisions are surfaced before their consequences become permanent.

The historical sequence matters. IBM's OS/360 (1964) established mandatory compensation boundaries — region sizes, operator-in-the-loop escalation via WTO/WTOR — before UNIX existed. UNIX's designers chose a different philosophy: permissive defaults, graceful degradation, opt-in resource limits. The distributed systems community inherited UNIX's choice wholesale. The formal framework presented here provides the mathematical basis for IBM's original design: there is a computable boundary h\* below which automated recovery is provably safe and above which it is provably intractable under production load. IBM enforced this boundary by convention; the framework shows it can be derived from measured system parameters.

### 6. Decision Authority Tracks Recovery Fitness

The design principle:

> A system may automate recovery when it can demonstrate that recovery bandwidth fits within available headroom — that h(t) > h\* for its current state. This is a computable condition: the gain matrix G and the spectral radius ρ(G) provide the test. When the condition holds, automated recovery is a proven contraction. When it does not hold, recovery under production load is intractable. The system's correct action is to emit diagnostic state and shut down, deferring recovery to an offline context where production load is zero and the bandwidth constraint is trivially satisfied.

| Decision | Can prove recovery fits? | Reversal cost if wrong | Action |
|----------|--------------------------|------------------------|--------|
| TCP retransmission | Yes (G = −0.5, contraction) | N/A (always converges) | Automate |
| Remove backend from LB | Yes (re-add costs one config update, L1-L3 trivial) | Bounded: seconds of wasted capacity | Automate |
| Cassandra hint replay | Depends: safe when R < R\* = D_t(1 − b/τ) − D_n | Offline reversible: must quiesce if burst exceeds L2 | Automate only if rate-limited by L2 headroom; shut down if headroom exhausted |
| OOM kill | No (restart cost unknown to kernel, L0 violation) | Unbounded: depends on process state, supervisor policy | Emit state, shut down |
| Tombstone GC | No (membership unknown, FLP regime) | Irreversible: zombie resurrection | Escalate to operator |

The governing variable is whether the system can prove — from its gain matrix and current headroom — that recovery converges. A load balancer removing a backend can prove this: re-adding costs one config update, satisfying L1-L3 trivially. Tombstone GC cannot: the consequences of being wrong (zombie resurrection) have no recovery action at all. Between these extremes, Cassandra hint replay illustrates the critical middle case: the recovery action is correct, but its bandwidth cost may exceed available headroom. The system must either throttle to fit (L2 bound) or shut down and recover offline.[^5]

### 7. Applying the Principles: CRDT Tombstone GC

CRDT[^6] tombstone garbage collection is a clean test case for the preceding principles, because it forces every question they raise.

CRDTs track deletions with tombstones — markers that say "this key was deleted at time T." A tombstone can only be GCed when *every* replica has observed the deletion, because removing it prematurely from any replica lets the pre-delete value reappear (the zombie resurrection problem from section 1). "Every replica has observed it" requires knowing two things: the group membership, and each member's progress. The first is a semantic fact about the physical world. The second is measurable.

**The slow-vs-dead problem is inescapable here.** A peer stops acknowledging — is it partitioned, overloaded, or decommissioned? This is exactly the FLP regime (section 2): no amount of observation from inside the system resolves it. Any system that GCs tombstones automatically must promote "unresponsive" to "gone" — an automatic semantic decision with unbounded consequences (silent data resurrection if wrong).

**Cassandra's approach crosses every boundary.** `gc_grace_seconds` is a wall-clock constant that assumes repair will propagate tombstones within 10 days. This is a semantic decision (section 1) disguised as a configuration parameter, made automatically by the system (section 5) with insufficient information (section 6). The recovery action — hinted handoff replay on node return — violates the recovery invariant (sections 3–4) by bursting accumulated writes into an already-stressed cluster.

**What the principles demand instead:**

1. **Separate what the system can measure from what it can't.** The system *can* measure: how many tombstones exist, how old they are, which peers have acknowledged which state, and how far behind each peer is. The system *cannot* determine: whether an unresponsive peer will return.

2. **Surface the measurable; defer the unmeasurable.** The API exposes what the system knows: `TombstoneCount()` reports pressure — how urgently GC is needed. `Status()` reports per-peer replication lag — who is behind and by how much. `BlockedBy(d)` names the specific peers preventing a given deletion from being GCed — the bottleneck, not just the symptom.

3. **Reserve the semantic decision for the entity with sufficient information.** `RemovePeer()` is the only call that declares a node gone. It requires the operator — the one entity that can check whether the hardware is dead, whether the network is partitioned, whether the node is being decommissioned. The system will not make this call on its own.

4. **Make the recovery action satisfy the invariant.** If a removed peer returns, it reconciles via *asymmetric* Merkle-tree anti-entropy — comparing hash trees with each replica, identifying divergent ranges, and pulling only the cluster's current state for those ranges. Reconciliation is pull-only: the returning node does not push stale data back to the cluster, preventing zombie resurrection for keys whose tombstones were GC'd after removal. No stored delta log is needed — divergence is discovered by comparing current state directly. Cost is O(|diff|): proportional to actual divergence, not to state size or absence duration. The returning node pulls at a rate bounded by level 2 headroom — available capacity minus current load — so the cluster does not experience a burst. The framework's own invariant defines the throttle: reconciliation proceeds while r(t) < C(t) − w(t) and pauses when headroom is exhausted.

The result is a compensation boundary drawn where the provability boundary actually is: the system automates recovery when it can prove recovery bandwidth fits within headroom (L2-throttled Merkle reconciliation), and surfaces everything else to the operator (peer membership decisions). No wall-clock constant substitutes for operator judgment. No automatic action has consequences that exceed available headroom.

### 8. Design Rules

Distill into actionable rules for system designers:

1. **Automate decisions whose reversal satisfies the recovery invariant. Escalate decisions whose consequences are irreversible or unbounded.** TCP can kill a connection (reversal: reconnect, L1-L3 trivial). Only an operator can decommission a node (reversal: rebuild, offline only).
2. **Derive timeouts from measured properties.** If you can't measure it, you can't timeout on it safely.
3. **Check all three levels of the recovery invariant.** Individual cost bounded (level 1) is necessary but insufficient — also verify that aggregate recovery rate doesn't exceed freed capacity (level 2) and that recovery actions don't feed back into the failure condition (level 3). If level 3 fails, it's a cascade seed.
4. **Surface state, don't hide it.** When you can't decide safely, expose what you know to whoever can.
5. **Make failure a first-class API.** TCP doesn't hide retransmissions from the application — it surfaces ETIMEDOUT. Your system shouldn't hide peer lag from the operator.
6. **If you cannot prove L1-L3 under current load, emit diagnostic state and shut down.** Don't attempt recovery that may violate the invariant. Don't continue operating in a state you cannot characterize. Shutdown is recoverable. Silent cascade is not.

[^1]: The term *compensating action* originates in transaction processing, where a compensating transaction undoes the effects of a committed transaction that cannot be rolled back (Gray & Reuter, *Transaction Processing: Concepts and Techniques*, Morgan Kaufmann, 1993). *Decompensation* — the exhaustion of adaptive capacity when recovery mechanisms become the dominant load source — is David Woods' contribution (see Related Work). The *compensation boundary* as used here — the architectural point where the system stops surfacing failure and starts acting on it — is a framing specific to this article, combining the transactional concept (what is a compensating action?) with the resilience engineering concept (when does compensation become the problem?) and adding the design question: *where should the system draw that line?*

[^2]: WLM (Workload Manager) is the z/OS component that classifies work into service classes with defined performance goals (response time, velocity, discretionary) and dynamically manages system resources — CPU dispatching priority, I/O priority, memory — to meet those goals. When goals cannot be met, WLM reports the shortfall rather than silently degrading. See IBM, *z/OS MVS Planning: Workload Management*, SC34-2662.

[^3]: XCF (Cross-system Coupling Facility) provides group membership, signaling, and heartbeat-based failure detection across z/OS systems within a sysplex. XCF monitors member health via configurable heartbeat intervals and declares a member failed when heartbeats stop — a local decision about connectivity. What that failure *means* for application-level state is delegated to recovery exits registered by the application, not decided by XCF itself. See IBM, *z/OS MVS Setting Up a Sysplex*, SA23-1399.

[^4]: SA z/OS (IBM System Automation for z/OS) is a policy-driven automation framework for z/OS operations. Operators author automation rules that define responses to system events; every automated action is logged and auditable. When no rule matches a condition, SA z/OS escalates to the operator rather than guessing. See IBM, *System Automation for z/OS Planning and Installation*, SC34-2571.

[^5]: DHCP lease expiry faces the same structural problem — "lease expired" is not "address unused" — but largely avoids it through protocol design: the client contractually agrees to stop using the address at expiry, and Duplicate Address Detection (RFC 5227) catches most residual conflicts. The type error exists but the protocol mitigates it bilaterally rather than ignoring it. Contrast Cassandra's `gc_grace_seconds`, where no such mitigation exists — the wall-clock constant is the entire mechanism.

[^6]: CRDT (Conflict-free Replicated Data Type) — a family of data structures that can be replicated across multiple nodes, updated independently and concurrently, and merged deterministically without coordination. The merge function is mathematically guaranteed to converge (it forms a join-semilattice), which eliminates the need for consensus on every write — at the cost of carrying metadata, including tombstones, that can only be safely discarded when all replicas have observed it. See Shapiro, Preguiça, Baquero, Zawirski, "A comprehensive study of Convergent and Commutative Replicated Data Types," INRIA Technical Report RR-7506, 2011.

---

## Notes / Things to Flesh Out

- [x] ~~Cite specific IBM documentation~~: z/OS MVS Planning: Workload Management (SC34-2662), z/OS System Automation Planning and Installation (SC34-2571), XCF heartbeat/failure detection in z/OS MVS Setting Up a Sysplex (SA23-1399). Now cited in footnotes [^2], [^3], [^4].
- [x] ~~Cassandra hinted handoff burst-on-return~~ — no clean public postmortem found, but [CASSANDRA-13984](https://issues.apache.org/jira/browse/CASSANDRA-13984) documents a production case: hint replay caused half the cluster to show as DOWN for ~21 minutes, with hint delivery stuck in "partially" state due to stale TCP connections. DataStax docs acknowledge that a 10-minute restart at 100 Mbps/node creates ~7 GiB of hints taking ~2 hours to replay at the default 1024 kbps throttle, and that at CL.ANY hinted handoff "can increase the effective load on the cluster."
- [x] ~~TCP `tcp_retries2`~~ — verified. Default 15 yields ~924.6s (~15.4 min) at `TCP_RTO_MIN` (200ms); upper bound depends on measured RTT and `TCP_RTO_MAX` (120s). 13–30 minute range is accurate. ([pracucci.com](https://pracucci.com/linux-tcp-rto-min-max-and-tcp-retries2.html), [tcp(7) man page](https://man7.org/linux/man-pages/man7/tcp.7.html))
- [ ] The "graceful degradation becomes ungraceful" pattern — David D. Woods calls this **decompensation**: the exhaustion of adaptive capacity under sustained disruption. Related concept: **brittleness** (sudden collapse beyond boundaries). Cite: Woods, *"Four concepts for resilience and the implications for the future of resilience engineering"* (2015); Woods, *"The theory of graceful extensibility"*, Environment Systems and Decisions 38, 433–457 (2018); Hollnagel, Woods, Leveson, *Resilience Engineering: Concepts and Precepts* (2006). Woods also introduced **graceful extensibility** as the opposite of brittleness — distinguish from our compensation boundary concept (we ask *where* the system draws the line; Woods asks *whether* it can extend capacity at all).
- [ ] Consider whether to frame as "here's what we built" (project-specific) or "here's a design principle" (general). Probably the latter, with the CRDT example as illustration.
- [x] ~~The FLP impossibility connection~~ — moved into section 2. Consider whether the Chandra-Toueg failure detector formalism deserves its own subsection or stays as a paragraph in section 2.

### Prior Art / Position Against

- [ ] **Metastable failures (the phenomenon).** The recovery-amplifies-failure pattern is well-identified under multiple names. Position sections 3–4 against this body of work — we share the phenomenon but formalize differently (gain matrix / spectral radius vs. CTMCs / queuing theory).
  - Bronson, Aghayev, Charapko, Zhu, *"Metastable failures in distributed systems"*, HotOS 2021. Coined the term. Key claim: "the root cause of a metastable failure is the sustaining feedback loop, rather than the trigger." Maps to our level 3 / feedback bound. ([PDF](https://sigops.org/s/conferences/hotos/2021/papers/hotos21-s11-bronson.pdf))
  - Huang, Magnusson, et al., *"Metastable Failures in the Wild"*, OSDI 2022. Empirical study of 22 metastable failures across 11 organizations. Taxonomizes triggers (load-spiking vs capacity-decreasing) and amplification mechanisms (workload amplification vs capacity degradation). >50% involved retry storms. ([USENIX](https://www.usenix.org/conference/osdi22/presentation/huang-lexiang), [PDF](https://www.usenix.org/system/files/osdi22-huang-lexiang.pdf))
  - Isaacs, Alvaro, Majumdar, Muniswamy-Reddy, Salamati, Soudjani, *"Analyzing Metastable Failures"*, HotOS 2025. Proposes a modeling pipeline (CTMC → DES → emulation → stress test) for discovering susceptibility at design time. ([PDF](https://sigops.org/s/conferences/hotos/2025/papers/hotos25-106.pdf), [ACM DL](https://dl.acm.org/doi/10.1145/3713082.3730380))

- [ ] **Metastable failures (formal analysis).** The metastable failures community is actively formalizing, but from stochastic processes / queuing theory, not control theory / gain matrices. Complementary approaches to the same phenomenon.
  - *"Formal Analysis of Metastable Failures in Software Systems"*, arXiv:2510.03551, Oct 2025. CTMC-based formalization with spectral characterization of metastable states (eigenvalue structure of the generator matrix, building on Bovier et al.). Asks "how long does the system stay trapped?" — our approach asks "does the perturbation converge or diverge?" ([arXiv](https://arxiv.org/abs/2510.03551))
  - *"MSF-Model: Queuing-Based Analysis and Prediction of Metastable Failures in Replicated Storage Systems"*, arXiv:2309.16181, 2023. Queuing model with orbit spaces for retry modeling. ([arXiv](https://arxiv.org/abs/2309.16181))

- [ ] **Control theory applied to computing systems.** Hellerstein et al. is the prior art for the *technique* (control theory for computing) but applied to a different *question* (controller design — admission control, scheduling — not analyzing when existing recovery mechanisms cascade).
  - Hellerstein, Diao, Parekh, Tilbury, *Feedback Control of Computing Systems*, Wiley/IEEE Press, 2004. Covers SISO/MIMO, transfer functions, gain, pole placement, stability for computing systems. ([Wiley](https://onlinelibrary.wiley.com/doi/book/10.1002/047166880X))

- [ ] **Cascading failure dynamics with control-theoretic stability analysis (other domains).** The gain matrix + Lyapunov stability approach has been applied to cascading failures in financial networks, not computing systems.
  - Ramirez & Bauso, *"Cascading failures: dynamics, stability and control"*, 2023. Financial cross-holdings as feedback, positive systems theory, Lyapunov stability. ([arXiv](https://arxiv.org/abs/2305.00838))

- [ ] **Exponential backoff stability.** TCP's backoff properties are well-studied. The "On the Stability of Exponential Backoff" line of work proves binary EB is stable under throughput definitions of stability. Our use of TCP is pedagogical (reference design for safe recovery) rather than a new formal claim about TCP itself.
  - *"On the Stability of Exponential Backoff"*, PMC/ResearchGate. ([PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC4846233/))
  - Bender et al., *"Scaling Exponential Backoff"*, JACM 2018 — constant throughput, bounded failed attempts, robustness under adversarial conditions.

- [ ] **Google SRE on cascading failures.** The retry budget (cap retries at 10% of total requests) is an explicit level-2 mechanism. The SRE book documents the phenomenon and mitigation patterns but doesn't formalize the stability condition.
  - [Google SRE Book — Addressing Cascading Failures](https://sre.google/sre-book/addressing-cascading-failures/)

- [ ] **Marc Brooker on metastability.** Useful practitioner perspective connecting the academic work to real systems.
  - Brooker, *"Metastability and Distributed Systems"*, 2021. ([Blog](https://brooker.co.za/blog/2021/05/24/metastable.html))
