# Architecture decisions

Short, durable records of decisions that shape MeshLab's architecture and its
relationship to the NumericCore ecosystem.

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-numerical-ownership.md) | Accepted | MeshLab owns geometry, 3D elements, assembly, rendering, and UX; NumericCore owns numerical algorithms and solvers. |
| [0002](0002-dependency-and-release-policy.md) | Accepted | Consume released `Swift-NumericCore` 1.x tags, commit `Package.resolved`, and upgrade deliberately with tests and benchmarks. |
| [0003](0003-sparse-solver-facade.md) | Accepted | Keep `SparseSolver` as the public facade over reusable NumericCoreSparse LU/LDLT factorizations, with explicit settings and diagnostics. |

When a decision changes, add a new ADR that supersedes the old one rather than
silently rewriting history.
