# ADR 0011: Advanced design and scale

- Status: Accepted
- Date: 2026-10-26

## Context

MeshLab's first design loop can sweep one primary response objective and run
compliance-based topology or shape optimization. Its batch worker executes
independent requests with bounded concurrency, but an interrupted job must
repeat every request. P9 needs to improve design decision support and practical
scale-out without adding a remote service, weakening reproducibility, or moving
FEA-specific policy into NumericCore.

Swift-NumericCore and Rust-NumericCore own reusable optimizers, sparse solvers,
and compute kernels. MeshLab owns the meaning of engineering response metrics,
project serialization, study orchestration, and worker result semantics.

## Decision

1. Extend Cartesian parametric studies with zero or more hard upper constraints
   over compliance, maximum displacement, and maximum von Mises stress. Select
   the primary optimum only from feasible samples and report an explicit error
   when no sample is feasible.
2. Compute a deterministic non-dominated set over a non-empty, unique list of
   response objectives. Pareto membership is evaluated only among feasible
   samples and preserves original sample order.
3. Keep exhaustive sampling bounded at 4096 points. P9 does not present this as
   a continuous multi-objective optimizer or uncertainty quantification method.
4. Export every design kind as CSV: parametric response/feasibility/Pareto
   rows, topology element densities and stiffness scales, or shape-variable
   coordinates and bounds. The workbench reports feasible and Pareto counts.
5. Assign every sweep request a deterministic FNV-1a fingerprint computed from
   its sorted-key JSON representation. A previous summary is reusable only when
   both request ID and fingerprint match. This hash guards identity and is not a
   security primitive.
6. Reuse matching successful summaries by default. Matching failures are also
   retained unless the caller requests retries. Changed requests always run.
   Preserve job order and bounded concurrency for the remaining work, and
   report resumed/executed request counts.
7. Add `--resume` and `--retry-failures` to `MeshLabSweep`. Resume remains a
   local result-file operation at request boundaries; it is not a distributed
   checkpoint protocol.
8. Advance the project schema to v8. Missing constraint and Pareto fields in
   v1–v7 documents decode to no constraints and all response metrics.

## Consequences

- Design exploration can distinguish infeasible candidates and expose tradeoff
  sets without introducing another optimization backend.
- NumericCore remains responsible for reusable continuous optimization and
  linear algebra. Pareto classification and sweep identity remain lightweight
  MeshLab orchestration policies.
- A completed request is not recomputed after worker interruption when its full
  definition is unchanged. Editing any encoded request field invalidates reuse.
- Resume result files remain portable and inspectable JSON, but the entire job
  and summaries are still held in memory.
- FNV-1a collisions are theoretically possible. The fingerprint is sufficient
  as a stale-result guard, not for adversarial integrity or authentication.

## Follow-up

- Add adaptive sampling, surrogate models, uncertainty propagation, and robust
  design once their reusable algorithms have a suitable NumericCore home.
- Add per-iteration progress and checkpoints for long topology, shape,
  nonlinear, and coupled requests.
- Move artifacts to content-addressed storage before introducing distributed
  workers, leases, or authentication.
- Add reusable multi-right-hand-side production solves and sparse/matrix-free
  nonlinear tangents through stable Swift-NumericCore interfaces.
