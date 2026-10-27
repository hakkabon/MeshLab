# Proposed NumericCore linear-operator contract

MeshLab requires a released Swift-NumericCore abstraction with these semantics:

- a `Sendable` square operator exposing dimension and `multiply`;
- optional diagonal extraction for Jacobi preconditioning;
- CG for symmetric-positive-definite operators;
- GMRES for general operators;
- explicit convergence, iteration, residual, and breakdown diagnostics;
- cancellation/iteration observation without callbacks crossing UniFFI per
  matrix-vector product;
- batched or coarse-grained Rust execution when the operator is representable by
  a portable expression or element-contribution buffer.

MeshLab's `FEMLinearOperator` is the current consumer-side adapter. Once the
upstream contract is available in a released 1.x version, it should conform or
wrap that protocol and `MatrixFreeConjugateGradient` should be removed.

The FFI boundary must remain coarse-grained. A Swift closure invoked from Rust
for every Krylov product would erase much of the portability and performance
benefit; either execute Krylov in Swift over a Swift operator or lower the
operator into portable contribution buffers executed entirely in Rust.
