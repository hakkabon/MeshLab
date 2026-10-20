# 0001: Numerical ownership and the MeshLab/NumericCore boundary

- Status: Accepted
- Date: 2026-10-20

## Context

MeshLab grew out of a need to prove an Apple-native FEM and visualization
foundation quickly. That led to local implementations of CSR assembly, direct
and iterative solves, element kinematics, and static analysis. At the same
time, the NumericCore ecosystem already provides a much broader numerical
substrate:

- `Swift-NumericCore` exposes `Matrix`/`Vector`, Accelerate/MPS/Rust dispatch,
  sparse factorization, iterative solvers, nonlinear systems, time
  integration, optimization, AMPL modeling, engineering models, 2D continuum
  FEM, truss dynamics, sensitivities, and multiphysics design.
- `Rust-NumericCore` provides the portable kernels, sparse direct/iterative
  solvers, decompositions, optimization, DAE, circuits, and FEM implementations
  behind the Swift package's binary FFI target.

Without an explicit boundary, MeshLab will drift into a second numerical stack.
That would duplicate maintenance, validation, and release engineering, and it
would make it unclear which implementation is authoritative.

## Decision

MeshLab and NumericCore have **layered ownership**.

| Layer | Owner | MeshLab's role |
| --- | --- | --- |
| Dense kernels, dispatch, Accelerate/MPS backends | `Swift-NumericCore` | Consume |
| Sparse formats, direct factorizations, preconditioned iterative solvers | `NumericCoreSparse` / Rust `nc-sparse` | Consume through a thin MeshLab-facing facade |
| Nonlinear systems, time integration, optimization, sensitivities | `NumericCoreOptimization` / Rust `nc-optimize` | Consume; contribute 3D requirements upstream |
| 2D continuum, thermal, truss, and structural dynamics | `NumericCoreOptimization` | Reuse where applicable; align contracts |
| 3D geometry, meshing, 3D element formulations, global assembly | MeshLab | Own and incubate |
| Rendering, SwiftUI, document/workflow UX | MeshLab | Own |

Specific rules:

1. **MeshLab must not become a second general numerical library.** New solver
   algorithms, factorizations, nonlinear methods, and optimization loops should
   normally be consumed from NumericCore rather than reimplemented here.
2. **MeshLab may keep a thin compatibility facade** over NumericCore types so
   rendering and application code do not depend directly on NumericCore APIs.
3. **3D FEM is incubated in MeshLab.** Constant-strain tetrahedra, triangular
   shells, meshing, and 3D assembly currently have no complete upstream home.
   Once the contracts and element library stabilize, reusable parts should move
   to a shared NumericCore FEM module rather than remaining application-local.
4. **Rust stays behind Swift-NumericCore.** MeshLab does not import `NCBindings`
   or generated UniFFI symbols directly. The Swift package owns the FFI
   boundary, version alignment, and binary distribution.
5. **Numerical ownership is not the same as model ownership.** MeshLab owns the
   3D model, units, coordinate conventions, boundary conditions, and result
   fields. NumericCore receives arrays, sparse operators, and solver contracts.
6. **There is one numerical truth per algorithm.** Temporary duplication is
   allowed only with an explicit migration task and validation coverage.

## Consequences

- `MeshLabCore.SparseSolver` should evolve into a facade over
  `NumericCoreSparse` rather than growing more local solver implementations.
- New physics should first ask whether NumericCore already provides the
  numerical method; MeshLab should supply element assembly and domain semantics.
- 3D element kernels remain local until a shared contract exists, but they must
  not fork general solver logic.
- Validation is an integration concern: MeshLab reference cases verify the
  combined MeshLab/NumericCore path, not a private numerical universe.
- Upstream needs such as 3D continuum FEM, higher-order elements, and 3D
  dynamics should be tracked as explicit contributions to NumericCore.

## Alternatives considered

- **MeshLab owns all FEM and numerics.** Rejected. It maximizes short-term
  control but duplicates a large, actively evolving numerical platform.
- **NumericCore owns all FEM, and MeshLab becomes a pure front end.** Rejected
  for now. NumericCore's current FEM contracts are primarily 2D and do not yet
  cover MeshLab's 3D requirements; forcing that boundary now would slow both
  projects.
- **MeshLab consumes Rust-NumericCore directly.** Rejected. It bypasses the
  Swift package's release and API-stability layer and makes FFI version skew an
  application concern.

## Follow-ups

- P1: replace local solver internals with a `NumericCoreSparse`-backed facade.
- P1: add 3D patch, cantilever, and membrane validation cases.
- Define the element/assembly seam (local residual/Jacobian/mass) and the
  field/render seam (`RenderScene`).
- Open upstream proposals for 3D continuum FEM and 3D structural dynamics once
  the local implementations are validated.
