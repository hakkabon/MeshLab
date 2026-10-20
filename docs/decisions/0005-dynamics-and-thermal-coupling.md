# 0005: 3D dynamics and one-way thermal-structural coupling

- Status: Accepted
- Date: 2026-10-20

## Context

P1 and P2 established a stable numerical facade and a product workflow, but the
analysis path was still limited to linear static equilibrium. P3 adds physics
breadth: 3D modal and transient dynamics plus steady thermal and thermal-stress
analysis.

NumericCore already provides truss dynamics, 2D thermal triangles, and general
time-integration types. Those models are useful references, but they do not
expose 3D tetrahedral mass, conduction, or thermal-strain assembly. MeshLab
owns 3D element formulations and assembly under ADR 0001, so P3 implements the
missing 3D formulations while continuing to use the `SparseSolver` facade and
`SparseMatrix` convention from P1.

## Decision

1. **Mass and conduction stay element-local.** `ElementKinematics` gains a
   consistent `tet4`/`tri3` mass matrix and an isotropic steady-conduction
   matrix. The same shape gradients, measures, and material model are used by
   stiffness, mass, conduction, and thermal-strain recovery.
2. **Modal analysis is constrained and dense.** `ModalAnalysis` assembles the
   global stiffness and mass matrices, reduces out homogeneous Dirichlet DOFs,
   and solves `K φ = λ M φ`. The reduced problem is dense because ModalCore does
   not yet expose a public sparse generalized eigensolver. Modes are
   mass-normalized and reported in ascending frequency order.
3. **The dense eigensolver is an internal LAPACK adapter.** MeshLab wraps
   Accelerate's `dsygv` behind an internal helper. This keeps the general
   numerical algorithm out of the public model API and leaves a clear path to
   replace it with a NumericCore eigensolver when one is available.
4. **Transient dynamics uses average-acceleration Newmark.** `TransientAnalysis`
   integrates `M u'' + C u' + K u = f(t)` with Rayleigh damping
   `C = αM + βK`. It reuses the sparse solver facade for the mass and effective
   stiffness systems. Modal and transient constraints must be homogeneous.
   NumericCore's exposed `TimeIntegrator` is an adaptive ODE/DAE integrator,
   not a fixed-step structural Newmark path over assembled FEM matrices, so
   this thin structural wrapper remains in MeshLab pending an upstream
   contribution.
5. **Thermal analysis is steady conduction.** `ThermalAnalysis` supports
   Dirichlet temperatures, nodal heat, volumetric heat generation, and
   element heat-flux recovery on tet4/tri3 meshes.
6. **Coupling is one-way thermal strain.** `FEMModel.temperatureChange` adds the
   equivalent thermal load `∫ Bᵀ D εth dV` to a static solve and subtracts the
   free thermal strain during stress recovery. The same path is exposed through
   `ThermalStressAnalysis`. Thermal-stress coupling currently requires 3D
   because the plane-strain reduction needs a separate thermal-stress term.
7. **The project schema advances to v2.** Analysis kind, modal display settings,
   and the thermal study travel with the project. Version 1 projects still
   decode with static analysis and zero thermal material properties.
8. **The workbench exposes static, modal, and thermal-structural studies.**
   Modal mode shapes are rendered through the existing displacement buffer;
   the stress heatmap is disabled for modal results. Thermal results render the
   coupled static stress field and expose nodal temperatures in the inspector.
   Transient dynamics remains a library API in P3.

## Validation

- A fixed-free bar's first axial frequency matches the uniaxial-strain wave
  speed for the laterally constrained discrete model.
- Modal modes satisfy the generalized residual and mass orthogonality checks.
- An undamped first-mode transient returns to its initial state after one
  period; mass and stiffness damping dissipate strain energy, and the damped
  Newmark equilibrium residual remains small.
- A steady thermal bar reproduces a linear temperature field and constant heat
  flux.
- Unrestrained thermal expansion is stress-free, while a fully constrained
  uniform temperature change produces the expected uniform compression.
- Project v1 migration, v2 round trips, and modal/thermal CSV exports are
  covered by tests.

## Consequences

- P3 adds 3D modal, transient, and steady thermal-structural capability without
  changing the existing static solve contract.
- Modal analysis is limited by dense eigensolver memory and cubic cost. Sparse
  modal analysis is a follow-up.
- Transient analysis is not yet exposed in the workbench and does not support
  time-dependent prescribed displacements.
- Thermal stress is limited to 3D; plane-stress/plane-strain thermal coupling
  needs a separate reduced constitutive derivation.
- Project v2 files are rejected by older clients, while v1 files migrate
  automatically on read.

## Follow-ups

- Add sparse modal analysis or contribute a generalized eigensolver to
  NumericCore.
- Contribute the fixed-step structural Newmark path to NumericCore or adapt it
  to the existing DAE integrator.
- Add transient thermal analysis and convection/radiation boundary conditions.
- Add two-way and staggered multiphysics coupling.
- Add plane-stress/plane-strain thermal-strain terms.
- Expose transient load histories and animation in the workbench.
