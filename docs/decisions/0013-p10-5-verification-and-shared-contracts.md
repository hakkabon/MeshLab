# ADR 0013: P10.5 verification and shared numerical contracts

- Status: Accepted
- Date: 2026-10-27

## Context

P10 established controlled engineering qualification, but its numerical
provenance named only the Swift-NumericCore 1.x compatibility family. Production
linear studies rebuilt an identical stiffness system for every case, transient
dynamics had no product workflow, acceptance limits had no presentation-unit
contract, and the current element implementations had no public residual/state
seam suitable for higher-order or path-dependent formulations.

MeshLab consumes released Swift-NumericCore tags. It must not adopt an
unreleased sibling API or import Rust-NumericCore directly merely to complete a
cross-repository migration in one commit.

## Decision

1. Project schema v10 adds `EngineeringUnitSystem` and `TransientStudy`.
   Requirement values remain canonical SI solver values; unit selections affect
   entry and presentation only.
2. Qualification and validation artifacts embed `NumericStackProvenance`: exact
   Swift-NumericCore and packaged Rust-NumericCore releases, compatibility epoch,
   manifest schema, ordered capabilities, and a deterministic manifest digest.
   A repository check keeps the declared Swift release aligned with
   `Package.resolved`.
3. The standard validation suite is a committed corpus. CI fails on case or
   metric drift, numerical-stack drift, or observation changes outside declared
   tolerances.
4. `PreparedLinearStaticAnalysis` assembles and factors one fixed linear system
   and accepts multiple load vectors. Production studies use one preparation for
   all load cases and combinations. The solver facade also exposes explicit
   multiple-right-hand-side methods.
5. `FEMElementKernel` defines the stable MeshLab-side element seam: request,
   residual, tangent, consistent mass, recovered stress, energy, and opaque
   history state. The current tri3/tet4 adapter implements this contract.
6. Transient analysis becomes a schema, batch, qualification, CSV, and workbench
   workflow. The workbench scrubs computed displacement states; stress-history
   recovery remains a separate future feature.
7. The workbench gains bounded production-study authoring for named-region
   constraints, region load cases, and combinations.
8. General matrix-free Krylov and sparse generalized eigensolvers remain
   NumericCore responsibilities. Their required consumer contracts are recorded
   under `docs/contracts`; MeshLab retains its existing local adapter until a
   released Swift-NumericCore version supplies them.

## Consequences

- A numerical dependency upgrade intentionally invalidates the committed
  validation baseline and requires review rather than silently retaining an old
  `1.x` label.
- Unit-display changes do not change physical acceptance thresholds after values
  have been converted to canonical storage.
- Production studies perform one assembly/factorization, while still recovering
  complete results independently for each right-hand side.
- The public element contract can incubate nonlinear state and higher-order
  formulations without exposing global solver or renderer concerns.
- The transient workbench holds its complete history in memory; streaming field
  storage is still required for large production histories.

## Follow-up

- Release the operator/Krylov and sparse-modal contracts from Swift-NumericCore,
  then replace MeshLab's local matrix-free CG and dense modal implementation.
- Obtain the packaged Rust version from a future public NumericCore runtime
  manifest instead of maintaining the checked release constant.
- Add editable load vectors, axes, factors, and material assignments to the
  bounded production authoring UI.
- Add transient stress recovery, playback, and streaming result storage.
