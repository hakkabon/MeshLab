# Architecture decisions

Short, durable records of decisions that shape MeshLab's architecture and its
relationship to the NumericCore ecosystem.

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-numerical-ownership.md) | Accepted | MeshLab owns geometry, 3D elements, assembly, rendering, and UX; NumericCore owns numerical algorithms and solvers. |
| [0002](0002-dependency-and-release-policy.md) | Accepted | Consume released `Swift-NumericCore` 1.x tags, commit `Package.resolved`, and upgrade deliberately with tests and benchmarks. |
| [0003](0003-sparse-solver-facade.md) | Accepted | Keep `SparseSolver` as the public facade over reusable NumericCoreSparse LU/LDLT factorizations, with explicit settings and diagnostics. |
| [0004](0004-product-workflow-and-project-format.md) | Accepted | Use versioned JSON projects, off-main-actor solves, CPU surface picking, and a legend that mirrors the Metal palette. |
| [0005](0005-dynamics-and-thermal-coupling.md) | Accepted | Add 3D consistent mass, modal/transient dynamics, steady thermal analysis, one-way thermal strain, and project schema v2. |
| [0006](0006-design-loop.md) | Accepted | Add parametric sweeps, self-adjoint compliance sensitivities, SIMP topology optimization, discrete shape optimization, and project schema v3. |
| [0007](0007-platform-and-scale.md) | Accepted | Add matrix-free static solves, batch sweep jobs and CLI, visionOS target support, and project schema v4. |
| [0008](0008-consolidation-and-interoperability.md) | Accepted | Add a public FEM operator seam, Gmsh/VTK interchange, deterministic validation reports, and project schema v5. |
| [0009](0009-production-linear-fea.md) | Accepted | Add named-region constraints/materials, load cases and combinations, envelopes, mesh quality, equilibrium reports, and project schema v6. |
| [0010](0010-nonlinear-and-coupled-engineering.md) | Accepted | Add finite-strain tet4 statics, NumericCore damped Newton iteration, staggered steady thermo-mechanical coupling, and project schema v7. |
| [0011](0011-advanced-design-and-scale.md) | Accepted | Add constrained Pareto exploration, design CSV export, fingerprinted sweep resume/retry, and project schema v8. |
| [0012](0012-engineering-platform.md) | Accepted | Add schema-v9 project provenance and acceptance criteria, deterministic qualification artifacts, workbench review, and the MeshLabReport CI worker. |
| [0013](0013-p10-5-verification-and-shared-contracts.md) | Accepted | Add exact NumericCore provenance, validation baselines, prepared linear systems, unit-aware qualification, element contracts, and transient/product workflow consolidation. |
| [0014](0014-p11a-elements-and-interoperability.md) | Accepted | Add higher-order solids, structural kernels, surface physics, sparse modal extraction, modern interchange, convergence estimation, and schema v11. |
| [0015](0015-p11b-nonlinear-production-depth.md) | Accepted | Add sparse adaptive Newton equilibrium, hyperelasticity, committed J2 plasticity, plane contact, prescribed motion, and schema v12. |
| [0016](0016-p11c-dynamics-and-multiphysics.md) | Accepted | Add implicit transient conduction, temperature-history Newmark coupling, transient thermo-mechanics, and schema v13. |
| [0017](0017-p11d-scale-and-execution.md) | Accepted | Add deterministic execution shards, atomic request checkpoints, fail-closed result merging, and content artifact identities. |

When a decision changes, add a new ADR that supersedes the old one rather than
silently rewriting history.
