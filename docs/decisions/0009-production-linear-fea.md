# 0009: Production linear FEA

- Status: Accepted
- Date: 2026-10-26

## Context

P6 made imported physical regions durable, but they were not yet actionable in
an analysis definition. A single global material, one anonymous load set, and
peak-only result reporting are adequate for examples but not for repeatable
engineering studies. Production linear work needs named boundary conditions,
independent load cases, factored combinations, heterogeneous materials,
traceable envelopes, mesh-quality evidence, and explicit equilibrium checks.

This phase stays within small-strain linear elasticity. It does not claim code
compliance, nonlinear behavior, contact, fatigue, or automatic safety factors.

## Decision

1. **Add a production-linear analysis kind.** `ProductionLinearStudy` stores
   shared region constraints, region material assignments, independent load
   cases, and factored combinations. Identifiers are stable and unique.
2. **Resolve named regions explicitly.** Region constraints expand to nodal
   component constraints. A region load is a documented total force divided
   equally over its unique nodes. No behavior is inferred from region names.
3. **Allow heterogeneous isotropic materials.** Full-dimensional regions map
   to per-element `ElasticMaterial` values. Unassigned elements use the project
   material, and overlapping assignments are rejected.
4. **Solve combinations as complete analyses.** Loads and body accelerations
   are factored and combined before solving. This preserves correct stress,
   energy, reactions, and diagnostics without incorrectly combining scalar
   result quantities.
5. **Produce traceable envelopes.** Nodal displacement magnitude and nodal von
   Mises envelopes carry the governing result identifier. The reported global
   peak stress remains the maximum element stress, avoiding under-reporting
   caused by nodal averaging.
6. **Report equilibrium.** Every static result carries applied and reaction
   force/moment resultants, imbalance vectors, and the maximum and relative
   free-DOF residual.
7. **Expose mesh-quality diagnostics.** `Mesh.qualityReport()` returns
   scale-independent element indicators, measures, inverted-element indices,
   and threshold queries.
8. **Advance projects to schema v6.** Versions 1–5 decode with an empty
   production study. The workbench can run a configured study, select any case
   or combination for rendering, show envelope peaks and equilibrium, and
   export every result in long-form CSV.

## Validation

- Two proportional load cases and a factored combination verify displacement
  and stress scaling and governing-result envelopes.
- Invalid region and load-case references are rejected deterministically.
- Region material assignment changes stiffness by the analytical ratio.
- Force and moment imbalance and the free residual are checked on a supported
  cantilever.
- Mesh quality reports orientation and scale-independent quality.
- Schema-v6 round-trip and schema-v5 migration are covered.
- The deterministic validation executable now includes structural equilibrium
  and a structured-mesh quality reference.

## Consequences

- Gmsh physical surfaces and volumes can drive repeatable analysis definitions
  without copying node or element indices into project files.
- Superseded by ADR 0013: assembled production studies now prepare and factor
  one common stiffness system for every load case and combination. Explicit
  matrix-free studies preserve their element-operator path and therefore rebuild
  that operator for each right-hand side.
- Region total forces are nodal distributions, not consistent pressure or
  traction integration. Face traction authoring remains available through
  explicit `Load.traction` values.
- Material assignment is isotropic and element-wise. Sections, orientations,
  orthotropy, shells, and beams remain future element/formulation work.

## Follow-ups

- Add workbench editors for region constraints, materials, load cases, and
  combinations beyond ADR 0013's bounded create/remove workflow, including
  detailed vector, factor, axis, and material editing.
- Add signed principal stress, tensor-component, reaction-table, and envelope
  CSV exports.
- Add convergence studies and error estimators before claiming mesh-independent
  engineering accuracy.
