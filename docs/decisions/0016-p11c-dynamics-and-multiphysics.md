# ADR 0016: P11C dynamics and multiphysics

- Status: Accepted
- Date: 2026-10-28

## Context

MeshLab had fixed-step structural Newmark dynamics, steady conduction, one-way
thermal stress, and staggered steady thermo-mechanics. It did not integrate the
thermal capacity term or carry an evolving temperature field through structural
dynamics. The released Swift-NumericCore 1.0.0 dependency still does not expose
the roadmap's general FEM time-integrator or GPU operator contract.

## Decision

1. Add a consistent scalar-capacity element operation shared by all supported
   continuum element types.
2. Integrate `C Tdot + K T = q` with the generalized trapezoidal method. The
   default backward-Euler setting is dissipative; theta 0.5 selects
   Crank--Nicolson. The constant effective matrix is factorized once through
   MeshLab's NumericCore sparse facade and reused for every step.
3. Extend Newmark dynamics with a nodal temperature history. Each state forms
   the existing equivalent thermal-strain load without changing structural
   stiffness or mass ownership.
4. Define transient thermo-mechanics as sequential coupling on one mesh and one
   time grid: integrate heat transfer, then advance mechanics with the matching
   temperature field. Each structural state retains its absolute temperature
   field for inspection and export consumers.
5. Persist coupling, volumetric heat capacity, theta, heat factors, and initial
   temperature in schema v13. Older projects default to uncoupled dynamics.
6. Integrate the coupled path into batch summaries, engineering qualification,
   and the workbench. A deterministic validation contract covers time-grid,
   residual, and thermal-energy behavior.

## Consequences

P11C adds production-useful transient heat transfer and thermal-strain dynamics
without inventing a second numerical stack. Constant matrices retain sparse
factorization reuse. Current coupling is sequential rather than monolithic, and
material coefficients do not yet vary within a time step. Transient radiation
is rejected until a nonlinear thermal tangent is implemented.

Generalized-alpha dynamics, nonlinear transient mechanics, monolithic field
Jacobians, acoustic/electromagnetic fields, released NumericCore operator and
Krylov APIs, Metal/MPS compute, distributed artifacts, and mid-request
checkpoints remain later increments. They should not be represented as released
capability until both Swift-NumericCore and Rust-NumericCore expose compatible,
versioned contracts.
