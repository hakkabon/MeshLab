# Proposed NumericCore sparse generalized-modal contract

MeshLab requires the lowest flexible modes of

`K φ = λ M φ`

for symmetric stiffness and positive-definite mass operators after constraint
elimination. The future NumericCore API should provide:

- assembled sparse and matrix-free stiffness/mass inputs;
- requested mode count, tolerance, iteration/subspace limits, and optional
  spectral shift;
- Lanczos/subspace iteration with shift-invert when a reusable factorization is
  supplied;
- mass-normalized vectors, eigenvalue/frequency, relative residual, and
  orthogonality diagnostics;
- deterministic mode ordering and a documented convention for repeated modes;
- cancellation and bounded workspace reporting.

MeshLab retains ownership of constraints, rigid-mechanism interpretation,
engineering frequency units, full-DOF expansion, and rendering. NumericCore owns
the eigensolver and reusable sparse linear algebra. Until this contract ships in
a released dependency, MeshLab's dense LAPACK implementation remains the
explicit small-model fallback.
