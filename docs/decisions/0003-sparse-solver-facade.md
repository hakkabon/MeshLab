# 0003: Sparse solver facade over NumericCoreSparse

- Status: Accepted
- Date: 2026-10-20

## Context

MeshLab originally owned a local `SparseSolver` implementation with separate
Accelerate and NumericCore paths. The NumericCore path created a fresh
factorization for every solve, even when the sparsity pattern was unchanged.
That duplicated symbolic analysis across load steps and exposed none of
NumericCore's refinement, inertia, or factorization diagnostics.

ADR 0001 establishes NumericCore as the numerical owner and allows MeshLab to
keep a thin compatibility facade. P1 turns that boundary into an implementation
rather than a future intention.

## Decision

1. **`MeshLabCore.SparseSolver` is the only public solver facade.** Geometry,
   FEM assembly, rendering, and application code continue to use MeshLab types.
   No target outside `MeshLabCore` imports NumericCore products directly.
2. **Reusable NumericCore factorizations back explicit NumericCore direct
   methods.** `.numericCoreLU` uses `SparseLUFactorization` and
   `.numericCoreLDLT` uses `SparseLDLTFactorization`. The initializer performs
   symbolic analysis and numeric factorization; `refactor(with:)` reuses the
   symbolic analysis when the sparsity pattern is unchanged.
3. **`.numericCoreCholesky` remains a one-shot convenience.** It uses
   NumericCore's validation and Cholesky path for callers that do not need
   factorization reuse. `.numericCoreLU` and `.numericCoreLDLT` are the
   reusable direct methods.
4. **Iterative methods stay on NumericCore's `SparseLinearSolver`.** CG,
   BiCGSTAB, and GMRES continue to accept `SparseIterativeSettings`; MeshLab
   does not implement preconditioners or Krylov loops.
5. **Accelerate remains a justified backend.** `.automatic` resolves to
   `.accelerateLDLT` for symmetric systems and `.numericCoreLU` otherwise.
   Explicit Accelerate Cholesky/LDLT methods remain available for Apple
   hardware comparisons and low-overhead solves.
6. **Direct settings are explicit and map to NumericCore.** `SparseDirectSettings`
   carries ordering, pivot/drop tolerances, and refinement controls. These map to
   `SparseOrdering` and `SparseNumericOptions` inside the facade.
7. **Diagnostics cross the boundary deliberately.** `SparseSolveReport` exposes
   factor nonzeros, relative residual, backward error, refinement steps, and
   LDLT inertia without leaking NumericCore types.
8. **MeshLab owns the matrix convention.** FEM assembly stores a lower-triangle
   CSR for symmetric matrices, matching Accelerate. The facade expands it to a
   canonical full CSR before calling NumericCore and rejects dimension or
   symmetry mismatches at the boundary.

## Validation

- A 3D patch test on a `2x2x2` structured box prescribes a linear displacement
  field on the boundary and checks the interior node and constant element
  stress.
- A 3D cantilever compares Accelerate LDLT, NumericCore Cholesky, NumericCore
  LU, and NumericCore LDLT displacement results.
- Reusable LU checks numeric refactorization, diagnostics, and rejection of a
  changed sparsity pattern.
- LDLT checks inertia reporting and requires an explicitly symmetric matrix.

## Consequences

- Load-step and nonlinear loops can factor once and call `refactor` per step
  instead of repeating symbolic analysis.
- MeshLab has one solver facade while retaining hardware-specific paths for
  performance comparison.
- `SparseSolveReport` is now the stable place for solver diagnostics; new
  NumericCore capabilities should be added there rather than exposed directly.
- NumericCore factorizations retain their own internal storage, so reusable
  solvers trade memory for faster repeated solves.
- Accelerate remains a second backend. It is acceptable because it is
  platform-optimized and hidden behind the same facade, but new general solver
  algorithms belong in NumericCore.

## Alternatives considered

- **Replace `SparseMatrix` with `NumericCoreSparse.SparseMatrix`.** Rejected.
  MeshLab's assembly format is FEM-specific, symmetric lower-CSR, and matches
  Accelerate; leaking NumericCore storage into assembly would couple the model
  layer to one backend.
- **Expose NumericCore types directly.** Rejected. It would violate the public
  facade, complicate minor upgrades, and spread numerical types through
  rendering and application code.
- **Keep the one-shot NumericCore path.** Rejected. It discards symbolic
  reuse and blocks load-step and nonlinear workflows.
- **Remove Accelerate entirely.** Rejected for now. It remains the preferred
  low-overhead path on Apple hardware and provides a useful independent check
  on NumericCore results.

## Follow-ups

- Add multi-load-step and nonlinear benchmarks that exercise `refactor`.
- Revisit factor memory strategies when mesh sizes make retained symbolic
  analysis expensive.
- Contribute 3D continuum element and assembly contracts upstream as they
  stabilize.
