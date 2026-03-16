# Recovery Invariant Executable Model — Design

**Date:** 2026-03-15
**Source:** `dont-let-your-system-decide-its-dead.md`
**Platform:** MATLAB R2024+ with Simulink and Symbolic Math Toolbox

## Goal

Executable MATLAB/Simulink model that encodes the article's formal assertions as computable functions. Four Simulink models (one per system), a shared analysis layer, and symbolic derivations. `run_all.m` reproduces every formal claim in the article.

## Architecture

```
models/
  build_tcp_model.m           — creates tcp_model.slx
  build_swap_model.m          — creates swap_model.slx
  build_cassandra_model.m     — creates cassandra_model.slx
  build_oom_model.m           — creates oom_model.slx
analysis/
  check_invariant.m           — Level 0/1/2/3 verdicts for any system
  compute_gain_matrix.m       — extract/compute G from system params
  find_hstar.m                — symbolic h* where closed-form exists
  sweep_stability.m           — vary load, plot ρ(G) vs headroom
symbolic/
  derive_tcp_stability.m      — prove G=-0.5 is unconditional contraction
  derive_swap_hstar.m         — derive E*/S = D'/(2f), cascade cond αβ≥1
  derive_perron_frobenius.m   — verify monotonicity for 2×2 non-negative G
run_all.m                     — reproduce all article assertions
```

## System Struct Convention

Every system is represented as a MATLAB struct:

```matlab
sys.name   = 'TCP';
sys.n      = 1;              % number of resources
sys.C      = 100;            % [n×1] capacity vector (bandwidth units)
sys.w      = @(t) 60;        % workload(t) → [n×1]
sys.r      = @(t,h) ...;     % recovery(t, headroom) → [n×1]
sys.delta  = 1;              % [n×1] cost of single recovery action
sys.G      = -0.5;           % [n×n] gain matrix (or @(h) for load-dependent)
```

## Invariant Checks

| Level | Condition | Implementation |
|-------|-----------|----------------|
| 0. Resource model | C, w, r defined in shared bandwidth units | Verify struct fields exist, dimensions match |
| 1. Individual | δ(a) bounded and known | `all(isfinite(sys.delta)) && all(sys.delta < sys.C)` |
| 2. Aggregate | h(t) ≥ 0 at all t | Simulate dynamics, check `min(h(:)) >= 0` |
| 3. Feedback | ρ(G) < 1 | `max(abs(eig(G)))` — evaluate at operating point if G is state-dependent |

## Model 1: TCP (Scalar, Unconditionally Stable)

**Resource:** Link bandwidth (segments/RTT)

**Parameters:**
- C = 100 segments/RTT (link capacity)
- w0 = 60 segments/RTT (normal traffic)
- RTO_base = 1 sec (from Jacobson estimator)
- max_retries = 15 (tcp_retries2 default)

**Simulink dynamics:**
1. Pulse generator: congestion spike (perturbation)
2. Counter: consecutive timeouts k
3. RTO computation: RTO_k = RTO_base × 2^k
4. Retransmission rate: r_k = 1/RTO_k
5. Headroom: h = C − w − r
6. Scopes: h(t), r(t), RTO(t)

**Expected result:** G = −0.5. r(t) decays exponentially after perturbation. No h* exists — unconditionally stable.

**Symbolic:** (I − G)⁻¹ = 2/3. Perturbation of size Δh produces bounded total recovery demand (2/3)Δh.

## Model 2: Swap (2×2 Cross-Resource, Closed-Form h*)

**Resources:** Memory (pages), Disk (IOPS)

**Parameters (64GB server, article defaults):**
- S = 16M pages (64GB / 4KB)
- W = working set (varied)
- f = page access rate (pages/sec)
- D_total, D_normal, D_spare = disk IOPS (total, normal, spare)

**Simulink dynamics:**
- Memory subsystem: excess E = W − S, fault probability E/W
- Disk subsystem: swap IOPS = 2f·E/W, plus normal IOPS
- α path (memory→disk): 2f/W IOPS per page of excess
- β path (disk→memory): blocked processes hold I/O buffers, increasing memory pressure
- Gain matrix: G = [ε, β; α, ε]
- Eigenvalues: ε ± √(αβ). Cascade when αβ ≥ (1−ε)²

**Parameter sweep reproduces article table:**

| Workload | f (pages/sec) | HDD (D'=100) | NVMe (D'=50000) |
|----------|---------------|---------------|------------------|
| Light web | 10,000 | 320 MB (0.5%) | no h* |
| Database | 100,000 | 32 MB (0.05%) | 16 GB (25%) |
| Analytics | 1,000,000 | 3.2 MB (0.005%) | 1.6 GB (2.5%) |

**Symbolic:** Derive E*/S = D'/(2f) in closed form. Verify monotonicity (Perron-Frobenius).

## Model 3: Cassandra Hinted Handoff (Two-Phase, Level 2+3 Violation)

**Resources:** Disk IOPS, CPU utilization

**Parameters:**
- write_rate = 10,000 writes/sec
- read_rate = 5,000 reads/sec
- T_outage = 600 sec (10 minutes)
- replay_throttle = 128 replays/sec (1024 kbps / ~8KB per hint)
- read_timeout = 0.5 sec
- repair_cost = 3 IOPS per read repair

**Phase 1 (outage, 0 ≤ t < T_outage):**
- Hints accumulate: hints(t) = write_rate × t
- At T_outage: ~6M hints

**Phase 2 (return, t ≥ T_outage):**
- Hints replay at replay_throttle
- Replay consumes disk IOPS on returning node

**Read latency model:** M/M/1 approximation: latency = base_latency / (1 − utilization)

**Level 3 cascade path:**
hint replay → disk contention → read latency spike → read timeout → read repair → more disk contention → ...

**Expected result:** Level 2 violated (burst on return). Level 3 violated (read repair feedback, ρ(G) > 1 under load).

## Model 4: OOM Killer (Feedback Gain Depends on External State)

**Resource:** Memory (pages)

**Parameters:**
- S = 16M pages (total system memory)
- n_procs = 50
- restart_delay = 2 sec
- alloc_rate = 50,000 pages/sec post-restart

**Dynamics:**
1. Total memory > S → kill largest process
2. Frees mem_victim pages
3. After restart_delay, supervisor restarts process
4. Restarted process allocates at alloc_rate
5. G = alloc_on_restart / mem_freed

**Victim selection:** Kill largest process (by RSS).

**Expected result:** G < 1 → stable. G ≥ 1 → kill/restart oscillation. Key insight: kernel cannot observe alloc_on_restart (determined by supervisor + application).

## Symbolic Derivations

### derive_tcp_stability.m
- G = −1/2, |G| = 1/2 < 1 at all loads
- (I − G)⁻¹ = 2/3 — bounded total recovery
- No h* exists (G constant, not load-dependent)

### derive_swap_hstar.m
- G = [ε, β; α, ε], eigenvalues ε ± √(αβ)
- ρ(G) = ε + √(αβ), cascade when αβ ≥ (1−ε)²
- Substitute α = 2f/W → E* = D'W/(2f) → E*/S = D'/(2f)
- Verify against article table values

### derive_perron_frobenius.m
- For 2×2 non-negative G: ∂ρ/∂Gᵢⱼ ≥ 0 (symbolic)
- ρ(G) non-decreasing in every entry
- h* boundary is a clean phase transition

## run_all.m Output

Summary table matching article:

```
System          | L0 Resource Model | L1 Individual | L2 Aggregate | L3 Feedback
----------------|-------------------|---------------|--------------|------------
TCP             | ✓ segs on link    | ✓ 1 segment   | ✓ backoff    | ✓ ρ=0.50
Swap (HDD,DB)   | ✓ pages + IOPS    | ✓ 1 page,2IO  | ✗ h<0 @32MB  | ✗ αβ>1
Cassandra       | ~ partial         | ✓ 1 write     | ✗ burst      | ✗ ρ>1
OOM (G=1.2)     | ✗ alloc unknown   | ✓ 1 kill      | ✓ single     | ✗ ρ=1.20
```

## Decisions

- **Simulink-first:** Each system is a Simulink model created programmatically by `build_*_model.m` scripts
- **M/M/1 latency model** for Cassandra read path (captures nonlinear blowup near saturation)
- **Kill-largest** heuristic for OOM (RSS-dominated in practice, keeps model focused on feedback dynamics)
- **Shared analysis layer** extracts G and checks invariant levels uniformly across all systems
