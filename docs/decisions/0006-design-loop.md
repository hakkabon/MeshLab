# 0006: Design loop — parametric studies and compliance optimization

- Status: Accepted
- Date: 2026-10-21

## Context

P0–P3 established a tested analysis stack, a versioned project format, and a
workbench for static, modal, and thermal-structural studies. The next step is a
closed design loop: explore parameter ranges, compute design sensitivities, and
modify the model toward a lower-compliance design.

NumericCore already exposes `LBFGSB`, bounds, and nonlinear termination through
`NumericCoreOptimization`. MeshLab owns the 3D element formulations, assembly,
loads, and project workflow, so the design studies are thin MeshLab adapters
around those numerical building blocks.

## Decision

1. **Parametric studies sweep project parameters with static solves.**
   `ParametricStudy` supports Young's modulus, Poisson ratio, thickness, and
   load scale. It builds a Cartesian product, validates every value, solves each
   variant with the project's static analysis settings, and reports compliance,
   displacement, and peak stress. Samples are capped at 4096 and the best sample
   is selected by the configured objective.
2. **Compliance sensitivities use the self-adjoint relation.**
   `ComplianceAdjoint` solves the primal static problem and computes
   `dC/ds_e = -u_eᵀK_eu_e` for each element stiffness multiplier. It requires
   homogeneous Dirichlet constraints and no thermal loading, which keeps the
   adjunct problem equal to the primal problem. Young's-modulus, thickness
   (2D), and load-scale derivatives are reported for project-level studies.
3. **Topology optimization uses SIMP plus an augmented Lagrangian.**
   `TopologyOptimization` assigns the stiffness scale
   `s_min + (1 - s_min)ρ^p`, differentiates the self-adjoint compliance
   sensitivity through that scale, and drives the density field with
   NumericCore's projected L-BFGS-B. A volume equality constraint is handled by
   an augmented Lagrangian, with an optional density-sensitivity filter for
   mesh dependence. The result carries every density, its stiffness scale, the
   iteration history, and a solved final model.
4. **Shape optimization moves selected node coordinates.**
   `ShapeOptimization` treats node-coordinate components as bound-constrained
   design variables. Its compliance gradient is the discrete self-adjoint
   expression `dC = 2uᵀdf - uᵀdKu`; assembled stiffness and load derivatives are
   evaluated with central differences, so no extra finite element solves are
   needed for the gradient. A volume equality constraint again uses an
   augmented Lagrangian around L-BFGS-B. Trial meshes are rebuilt through the
   normal `Mesh` initializer, so inverted or degenerate trials are rejected.
5. **Design results are library values, not UI state.**
   The optimization types are sendable value results and remain usable without
   SwiftUI. The workbench runs them in a detached task, displays summaries, and
   renders the best parametric sample plus topology/shape final fields through
   the existing `RenderScene`.
6. **The project schema advances to v3.**
   `DesignStudy` stores the selected study plus parametric axes, topology
   settings, and shape settings. Version 1 and v2 projects decode with an empty
   parametric study and default optimization settings.
7. **The workbench exposes the loop.**
   The sidebar can select a parametric, topology, or shape study, edit the
   common settings, run it asynchronously, and inspect its summary. Topology
   results are displayed through the optimized stiffness field; shape results
   replace the viewport geometry with the optimized mesh.

## Validation

- A parametric E/load sweep reproduces the expected compliance scaling and
  selects the stiffest, least-loaded sample.
- Element stiffness and Young's-modulus adjoint gradients match central finite
  differences of a full static solve.
- A cantilever topology study stays near its volume target, respects density
  bounds, and does not increase compliance.
- A shape sensitivity check matches finite differences of the full static
  solve, and a short shape study preserves a valid mesh and target volume.
- Project v1/v2 migration, v3 round trips, and every `DesignStudy` kind are
  covered by tests.

## Consequences

- The design loop reuses existing assembly and solver paths instead of adding a
  second FEM implementation.
- Compliance optimization is restricted to linear static problems with
  homogeneous Dirichlet constraints and no thermal loads.
- Topology optimization currently reports densities but does not render them as
  a density field; the viewport shows the optimized stiffness response.
- Shape optimization selects mesh nodes on the maximum-coordinate face. It is a
  demonstration of discrete shape sensitivity, not a CAD parameterization, and
  has no manufacturability or feature-preservation constraints.
- Optimization cost is proportional to the number of solves and design
  variables; the workbench keeps it off the main actor but does not yet provide
  live per-iteration progress.

## Follow-ups

- Add density and iteration-history visualization to the workbench.
- Add shape variables from CAD parameters, boundary-face selection, and
  feature-preservation constraints.
- Add multiple load cases, stress constraints, and manufacturing constraints.
- Extend the adjoint path to thermal and transient objectives.
- Add design-result export and optimization progress reporting.
