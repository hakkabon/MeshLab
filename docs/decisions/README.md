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

When a decision changes, add a new ADR that supersedes the old one rather than
silently rewriting history.
