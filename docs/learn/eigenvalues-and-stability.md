# Eigenvalues and Why They Decide If Your System Cascades

You understand the paper's argument up through Section 4: recovery actions cost resources, those costs can be individually bounded (Level 1) and collectively bounded (Level 2), and the dangerous case is Level 3 — when recovery actions feed back into the conditions that triggered them. The question Section 5 asks is: *how do you measure whether a feedback loop amplifies or dampens?*

That's where eigenvalues come in. But before we get there, we need to build up from something concrete.

## One Resource, One Number

Start with the simplest case: TCP. There's one resource — link bandwidth — and one recovery mechanism — retransmission. When the link gets more congested (headroom drops), TCP backs off exponentially: each congestion event *halves* the retransmission rate.

The paper captures this as a single number:

> **G = −0.5**

This is the *gain* of the feedback loop. It answers: "If headroom drops by one unit, how much additional recovery demand appears?" For TCP, the answer is −0.5 — recovery demand *decreases* by half a unit. The negative sign means recovery pushes *against* the problem instead of amplifying it.

Now imagine headroom drops by some amount Δh. Recovery demand changes by G · Δh. That changes headroom again, which changes recovery demand by G² · Δh. And again: G³ · Δh, G⁴ · Δh, and so on. The total effect is:

> Δh + G·Δh + G²·Δh + G³·Δh + ⋯ = Δh / (1 − G)

You might recognize this — it's a geometric series. It converges when |G| < 1. For TCP, |G| = 0.5, so the series converges. The perturbation decays. The system is stable.

For the OOM killer, G = alloc_on_restart / mem_freed. If the restarted process allocates *more* memory than the kill freed, G > 1. The geometric series diverges. Each round of kill-restart-allocate makes things worse. That's a cascade.

So far, no eigenvalues needed. One resource, one number, check if it's less than 1. Simple.

## The Problem: Two Resources That Talk to Each Other

Now consider UNIX swap. There are *two* resources: memory and disk I/O. When memory is under pressure, the system swaps pages to disk — consuming disk bandwidth. When disk is saturated, processes block waiting for I/O — and blocked processes hold memory (kernel I/O buffers, page tables, the pages they were working on).

Memory pressure → disk load → blocked processes → memory pressure.

This is a *cross-resource* feedback loop. You can't capture it with a single number, because the feedback doesn't go resource → same resource. It goes resource A → resource B → resource A.

The paper represents this with a 2×2 matrix — the gain matrix G:

```
G = [ ε    α ]     row 1 = disk
    [ β    ε ]     row 2 = memory
```

Each entry answers: "How much additional recovery demand appears on resource *i* when headroom on resource *j* drops by one unit?"

- α (top-right): memory headroom drops → more page faults → more disk IOPS. This is `2f/W` in the paper — two IOPS per fault, fault probability proportional to excess/working-set.
- β (bottom-left): disk headroom drops → processes block on I/O → blocked processes hold memory buffers.
- ε (diagonal): small self-feedback terms.

Now the same question: does a perturbation grow or shrink? If headroom drops by a vector Δ**h** (some on disk, some on memory), recovery demand increases by G·Δ**h**. That changes headroom, which changes demand by G²·Δ**h**. Total effect:

> (I + G + G² + G³ + ⋯) · Δ**h**

Same geometric series, but now with matrices instead of scalars. **When does a matrix geometric series converge?**

## What an Eigenvalue Actually Is

Here's the core idea, without the formalism first.

A matrix is a machine that takes a vector in and pushes a vector out. Most vectors get rotated, stretched, squished — they come out pointing in a different direction than they went in. But some special vectors come out pointing in the *same direction* — just scaled longer or shorter. Those special vectors are called **eigenvectors**, and the scaling factor for each one is its **eigenvalue**.

If G is 2×2, it has (at most) 2 eigenvectors, each with its own eigenvalue. Think of them as the "natural axes" of the feedback system — the directions along which the feedback loop acts purely as amplification or damping, without mixing resources.

Concretely for the swap system: one eigenvector might represent "disk and memory pressure increasing together" and another might represent "disk pressure up, memory pressure down." Each has its own eigenvalue — its own amplification factor.

### Computing Them

The definition says: an eigenvector **v** is a direction where G acts as pure scaling. Written as an equation:

> **G·v = λ·v**

λ (lambda) *is* the eigenvalue — the unknown scaling factor we're trying to find. "What are the eigenvalues of G?" means "for which values of λ does a non-zero vector **v** exist such that G·v = λ·v?"

Rearrange: G·v − λ·v = 0, or (G − λI)·v = 0, where I is the identity matrix. This has a non-zero solution for **v** only when the matrix (G − λI) is singular — meaning its determinant is zero:

> **det(G − λI) = 0**

This is called the *characteristic equation*. You plug in G, treat λ as the unknown, and solve. For a 2×2 matrix it gives you a quadratic — two solutions, two eigenvalues.

For the swap gain matrix with small ε:

```
det([ ε−λ    α  ]) = (ε−λ)² − αβ = 0
    [  β    ε−λ ])
```

Solving: **λ = ε ± √(αβ)**

Two eigenvalues. The larger one is ε + √(αβ).

## The Spectral Radius: The One Number That Matters

You don't need to care about every eigenvalue individually. You need one thing: the **spectral radius**, written ρ(G) — the largest absolute value among all eigenvalues.

> **ρ(G) = max |λᵢ|**

The matrix geometric series I + G + G² + ⋯ converges if and only if **ρ(G) < 1**.

Why? Think about what G^k does to a perturbation after k rounds of feedback. Decompose the perturbation along the eigenvectors. Along each eigenvector, G^k just multiplies by λᵢ^k. If |λᵢ| < 1, then λᵢ^k → 0 as k grows — that component decays. If |λᵢ| > 1, then λᵢ^k → ∞ — that component explodes. The spectral radius is the worst case. If the *largest* eigenvalue (in absolute value) is below 1, *every* component decays. If it's above 1, at least one component explodes.

That's the whole stability condition:

> **ρ(G) < 1  →  perturbations decay  →  stable**
> **ρ(G) ≥ 1  →  perturbations amplify  →  cascade**

For the swap system: ρ(G) = ε + √(αβ). Cascade when **αβ ≥ (1 − ε)²** — approximately when **αβ ≥ 1**. This is the cross-resource loop: memory pressure generates disk load (α), disk saturation generates memory pressure (β). If their *product* exceeds 1, the round-trip amplification exceeds unity, and the system cascades.

This is the key insight that eigenvalues give you: **even if each resource's self-feedback is small (ε ≪ 1), the cross-resource feedback can cascade when α·β ≥ 1.** Looking at each resource in isolation would miss this. The eigenvalue captures the compound effect of the whole loop.

## Why Not Just Multiply α·β Directly?

For a 2×2 matrix with equal diagonal entries, ρ(G) does reduce to a function of αβ. So why the eigenvalue machinery?

Because real systems can have more than two resources. Cassandra's hint replay involves disk I/O, CPU, network, and the read-repair mechanism — each potentially feeding back into the others. With *n* resources, G is *n×n*, and the feedback paths multiply combinatorially. There might be a loop through three resources: A → B → C → A. Checking every possible product of off-diagonal entries by hand doesn't scale and is error-prone.

The spectral radius handles all of this in one computation. No matter how many resources, no matter how tangled the feedback paths: compute G, compute its eigenvalues, check if the biggest one (in absolute value) is below 1. The eigenvalues encode *all* feedback loops — direct, indirect, and compound — into a single stability verdict.

In the MATLAB code, this is one line:

```matlab
rho = max(abs(eig(G)));
```

`eig(G)` returns all eigenvalues. `abs()` takes absolute values. `max()` picks the largest. That's the spectral radius. Compare it to 1. Done.

## h*: Where the Boundary Lives

The gain matrix G isn't constant — it depends on how loaded the system is. When load is low, α and β are small (plenty of headroom, feedback is weak). As load increases, α and β grow (less headroom means each perturbation generates proportionally more recovery demand).

There's a critical headroom **h\*** where ρ(G) crosses 1:

- **h > h\***: ρ(G) < 1, system is stable — perturbations decay
- **h < h\***: ρ(G) ≥ 1, cascade territory — perturbations amplify

The Perron-Frobenius theorem (mentioned in the paper) guarantees that for systems where G ≥ 0 (no backoff — recovery demand never *decreases* when headroom drops), the transition is monotone: once ρ(G) crosses 1, it stays above 1 as load increases further. The system can't self-rescue by getting *more* overloaded. h\* is a clean phase boundary.

The MATLAB code in `find_hstar.m` computes this. For swap, it's a closed form:

```matlab
h_star = D_prime * W / (2 * f);
```

For Cassandra, there's no closed form — the code sweeps replay rates, computes G and ρ(G) at each point, and finds where ρ(G) first hits 1:

```matlab
for i = 1:numel(throttles)
    p.timeout_fraction = estimate_timeout_fraction(p, throttles(i));
    G = compute_gain_matrix(p);
    rho_vals(i) = max(abs(eig(G)));
end
idx = find(rho_vals >= 1, 1, 'first');
```

## The Scalar Case Revisited

For systems with a single resource (TCP, OOM killer), G is a 1×1 "matrix" — just a number. A 1×1 matrix has one eigenvalue: itself. The spectral radius is |G|. Everything reduces to checking |G| < 1, which is the same as saying "does the feedback loop amplify?"

This is why the paper presents TCP first as G = −0.5 without mentioning eigenvalues. The single-resource case doesn't need the machinery. It's only when resources interact — swap's memory-disk loop, Cassandra's disk-CPU-read-repair loop — that you need eigenvalues to capture the compound effect.

## Summary

| Concept | What it means in this paper |
|---|---|
| Gain matrix G | How much additional recovery demand appears on each resource when headroom drops on each resource |
| Eigenvalue λ | Amplification factor along one "natural axis" of the feedback system |
| Spectral radius ρ(G) | Worst-case amplification factor across all feedback paths |
| ρ(G) < 1 | Perturbations decay — system is stable |
| ρ(G) ≥ 1 | Perturbations amplify — cascade |
| h\* | The load level where ρ(G) crosses from < 1 to ≥ 1 |

The eigenvalue is not a mysterious quantity. It's the answer to a concrete question: *if I poke this system, does the poke get bigger or smaller as it bounces around the feedback loop?* For one resource, that's just a number. For multiple resources, eigenvalues are how you account for every possible path the poke can take.
