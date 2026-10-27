# ADR 0015: P11B nonlinear production depth

- Status: Accepted
- Date: 2026-10-27

## Context

P8 established a deliberately bounded finite-strain `tet4` analysis. It used a
dense global Jacobian, fixed load increments, one elastic law, homogeneous
prescribed motion, and no contact or committed constitutive history. P11A added
the shared element-state seam but did not deepen nonlinear equilibrium.

## Decision

1. Assemble the total-Lagrangian tangent as sparse lower-triangle triplets and
   solve each Newton correction through MeshLab's `SparseSolver` facade over
   Swift-NumericCore. MeshLab continues to own element kinematics, residuals,
   and assembly.
2. Use adaptive load control with configurable growth, cutback, minimum and
   maximum increments, target iteration count, and bounded retries. Only a
   converged step commits displacement and constitutive state.
3. Support Saint Venant–Kirchhoff and compressible Neo-Hookean hyperelasticity
   with analytical directional tangents.
4. Add isotropic-hardening J2 return mapping in Green-strain/second-Piola space.
   Each `tet4` stores six plastic-strain components plus equivalent plastic
   strain. The algorithmic directional tangent is evaluated by centered
   differentiation of the return map. Trial Newton evaluations never mutate
   the last committed state.
5. Add frictionless node-to-plane penalty contact. Contact normals are
   normalized during validation, active penetration contributes residual,
   tangent and energy, and physical contact forces enter equilibrium reactions.
6. Ramp nonzero Dirichlet values with the load factor. This makes prescribed
   motion compatible with adaptive continuation.
7. Project schema v12 persists all new controls and contact definitions. A v11
   nonlinear-options payload defaults to its former fixed-step behavior;
   newly-created options enable adaptivity.

## Consequences

The global nonlinear memory footprint is sparse and difficult equilibrium paths
can recover through cutback. Neo-Hookean elasticity and committed J2 history
cover materially broader behavior, while contact and prescribed motion support
useful production boundary conditions.

The J2 model is not a multiplicative finite-plasticity formulation. Contact is
penalty-based and node-to-plane only. Arc-length continuation, friction,
surface-to-surface search, nonlinear higher-order solids, buckling extraction,
and distributed/matrix-free nonlinear solves remain P11C work. General-purpose
continuation and nonlinear sparse-solver contracts should migrate into
Swift-NumericCore when their released API can also serve Rust-NumericCore.
