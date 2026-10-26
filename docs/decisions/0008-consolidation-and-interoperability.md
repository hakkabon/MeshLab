# 0008: Consolidation and interoperability

- Status: Accepted
- Date: 2026-10-26

This decision supersedes decision 2 in ADR 0004.

## Context

P0–P5 established the analysis, design, application, and scale-out paths, but
three seams were still implicit. Matrix-free assembly was coupled to a private
concrete type, meshes could only enter through MeshLab JSON, and compatibility
was demonstrated by a broad unit suite without a small portable evidence
artifact. That made it harder to evolve MeshLab, Swift-NumericCore, and
Rust-NumericCore independently while preserving their shared numerical
contract.

Gmsh does not encode coordinate units. Physical groups, however, are the most
useful source of stable domain names for later load and boundary-condition
authoring. Import therefore needs explicit unit policy and must preserve those
groups without guessing analysis semantics.

## Decision

1. **Expose a minimal FEM linear-operator contract.** `FEMLinearOperator`
   carries only a dimension, diagonal, and matrix-vector product.
   `FEMElementContribution` and `FEMElementOperator` adapt MeshLab element
   assembly to that contract. Mesh ownership and element formulations remain
   in MeshLab.
2. **Keep the matrix-free CG adapter local until NumericCore has the matching
   public abstraction.** The new contract defines the intended integration
   seam. When Swift-NumericCore gains an operator-based Krylov API, MeshLab can
   replace its private iteration without changing element assembly. Any Rust
   implementation remains behind Swift-NumericCore's stable API and FFI layer.
3. **Import ASCII Gmsh 2.2 and 4.1.** Linear `triangle3` and `tetrahedron4`
   elements are accepted. The highest supported element dimension becomes the
   analysis mesh; lower-dimensional physical groups are retained as named node
   regions. Source coordinates use an explicit caller-supplied unit and are
   normalized to meters. Binary Gmsh and higher-order elements are rejected.
4. **Export legacy ASCII VTK.** Geometry, displacement vectors, and nodal von
   Mises values can be inspected in common post-processors. JSON remains the
   restartable project format; VTK is a review artifact.
5. **Advance the project format to schema v5.** `MeshMetadata` stores source
   format, normalized coordinate unit, and named regions. Versions 1–4 decode
   with empty metadata. Import does not infer constraints or loads from region
   names; the workbench shows the geometry and leaves the new study unsolved.
6. **Ship a deterministic validation artifact.** `MeshLabValidate` emits
   sorted JSON with no timestamp or host-specific fields. It checks the public
   operator contract, assembled versus matrix-free structural results, and an
   analytical linear thermal case. A failing case produces a nonzero exit.

## Validation

- Gmsh 2.2 and 4.1 fixtures verify connectivity, units, entity-to-physical-group
  mapping, and boundary-region preservation.
- VTK export verifies unstructured-grid topology and nodal result fields.
- Schema-v5 metadata round-trips; a schema-v4 document defaults cleanly.
- The operator contract is tested independently of the static solver.
- The deterministic validation suite passes and reproduces identical JSON.
- The full suite passes with 74 tests, including the Metal pipeline test.

## Consequences

- MeshLab can exchange first-order volume/surface meshes without acquiring a
  CAD kernel or silently inventing units.
- Named regions are durable project data and can support a later boundary-
  condition authoring UI.
- An imported `.msh` has no constraints by default and therefore cannot be
  solved until the user defines a valid study.
- The operator boundary is intentionally smaller than a general NumericCore
  protocol. It avoids duplicating sparse matrix, factorization, and optimizer
  APIs already owned by Swift-NumericCore.
- The validation JSON can be archived by all three repositories to distinguish
  API/FFI regressions from MeshLab formulation regressions.

## Follow-ups

- Propose an operator-based Krylov protocol and solver in Swift-NumericCore,
  backed by Rust-NumericCore only where the FFI overhead is coarse-grained and
  benchmark evidence supports it.
- Add a workbench editor that maps named regions to constraints and loads,
  rather than relying on naming conventions.
- Add binary Gmsh, higher-order element, VTU/XDMF, and time-series result
  support as independently tested adapters.
- Run `MeshLabValidate` in the Swift-NumericCore dependency canary and retain
  reports for cross-version comparison.
