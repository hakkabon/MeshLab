# ADR 0010: Nonlinear and coupled engineering

- Status: Accepted
- Date: 2026-10-26

## Context

P7 established a traceable linear-static workflow, but geometrically nonlinear
response and feedback between the thermal and structural fields were absent.
MeshLab already owns three-dimensional element kinematics and assembly, while
Swift-NumericCore provides a reusable damped nonlinear-system solver backed by
the wider Swift/Rust NumericCore stack. The next increment must preserve that
ownership boundary and produce results that the existing renderer, exporters,
batch runner, and workbench can consume.

A complete industrial nonlinear platform would also require several independent
capabilities: robust constitutive models, sparse nonlinear tangents, adaptive
continuation, contact, transient heat transfer, and monolithic multiphysics.
P8 therefore needs an explicit bounded formulation rather than implying those
capabilities.

## Decision

1. Add a total-Lagrangian finite-strain static analysis for three-dimensional
   `tet4` meshes. MeshLab computes deformation gradients, Green--Lagrange
   strains, Saint Venant--Kirchhoff stress, internal forces, and a consistent
   material/geometric tangent.
2. Apply external loading incrementally. At each fixed load step,
   `NumericCoreOptimization.NonlinearSystemSolver` owns damped Newton iteration,
   convergence tests, and line search; MeshLab supplies the residual and
   Jacobian evaluation.
3. Recover Cauchy stress in the deformed configuration and adapt the converged
   state into `StaticResult`, including reactions, strain energy, force/moment
   equilibrium, and free-DOF residuals. This preserves the established
   rendering and CSV contracts.
4. Initially require homogeneous prescribed displacements and reject inverted
   element configurations. The formulation is deliberately limited to `tet4`
   elements and a dense nonlinear Jacobian.
5. Add a partitioned steady thermo-mechanical analysis. Each coupling iteration
   solves conduction on a relaxed deformed geometry, then solves structural
   equilibrium on the reference mesh using the resulting thermal strain.
   An optional uniform temperature coefficient scales Young's modulus from the
   reference material. Relaxation and relative field-update tolerances control
   the staggered iteration.
6. Do not represent the staggered method as a monolithic two-way formulation.
   It does not include mechanical dissipation as a heat source, transient heat
   transfer, a coupled tangent, or spatially varying constitutive properties.
7. Extend the project format to schema v7 with nonlinear and coupled options;
   older schemas receive stable defaults. Expose both analyses through batch
   execution and the workbench.

## Consequences

- MeshLab gains a testable finite-strain path without duplicating a generic
  nonlinear algorithm already owned by NumericCore.
- The Swift API remains the integration boundary. MeshLab does not import Rust
  bindings directly; Rust-NumericCore may accelerate or replace kernels behind
  Swift-NumericCore without changing the element API.
- Fixed stepping and Saint Venant--Kirchhoff elasticity make the first slice
  understandable and deterministic, but they are not suitable for arbitrary
  large compression, path-dependent materials, or difficult limit points.
- Dense Jacobian construction limits nonlinear model size. A future operator or
  sparse nonlinear interface belongs in Swift-NumericCore when it can be made
  reusable; MeshLab should continue to own element residual/tangent assembly.
- The staggered coupling is useful when geometry and temperature-dependent
  stiffness feedback matter, while keeping the thermal and structural solvers
  independently verifiable. Strongly coupled problems may require relaxation
  tuning or a future monolithic method.

## Follow-up

- Add adaptive load stepping and continuation with step rejection/retry.
- Add objective hyperelastic models before targeting extreme deformation, then
  introduce path-dependent plasticity and contact as separate formulations.
- Move nonlinear linearization to sparse or matrix-free operators and expose
  reusable preconditioning through Swift-NumericCore.
- Add transient heat transfer, spatial material laws, mechanical heat sources,
  and eventually a monolithic coupled residual/tangent where justified.
- Establish cross-language nonlinear validation artifacts so Swift- and
  Rust-NumericCore implementations can be compared without weakening the Swift
  ownership boundary.
