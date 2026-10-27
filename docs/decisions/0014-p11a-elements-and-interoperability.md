# ADR 0014: P11A elements and engineering interoperability

## Status

Accepted and implemented.

## Decision

1. `ElementType` adds ten-node tetrahedra and eight-node hexahedra. Their
   continuum operators are integrated at four tetrahedral and eight hexahedral
   Gauss points respectively; the existing exact simplex mass rule is retained
   for `tet4` and `tri3`.
2. Pressure is an oriented face load. Convection and radiation are face-based
   thermal conditions; radiation is solved by bounded nonlinear iteration and
   fails closed if it does not converge.
3. Modal analysis selects dense or sparse-subspace extraction explicitly, or
   automatically from the reduced system size. The sparse implementation
   reuses one NumericCore sparse factorization across its block solves.
4. Beams and shells must not be disguised as translational continuum
   `ElementType` cases. `EulerBernoulliFrame2D` and
   `TriangularMembraneShell3D` instead emit arbitrary global-DOF element
   contributions through the public element-operator seam. The membrane
   kernel has no bending stiffness; a production shell-bending formulation is
   deliberately left for the next structural-element increment.
5. Gmsh 2.2/4.1 import recognizes `hex8`, `tet10`, quadrilateral boundaries,
   and quadratic-triangle boundaries. VTU and self-contained XDMF complement
   legacy VTK export.
6. Project schema v11 persists modal solver selection and thermal surface
   conditions. Older projects default to automatic modal selection and no
   surface exchange.

## Consequences

P11A broadens production linear and thermal coverage without changing the
three-translation-per-node continuum model. Mixed structural degrees of
freedom remain explicit and cannot accidentally enter continuum assembly.
Sparse eigensolver behavior stays behind a MeshLab adapter until equivalent
released Swift-NumericCore APIs are available; it should migrate upstream when
that contract stabilizes alongside Rust-NumericCore.
