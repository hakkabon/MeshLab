# ADR 0012: Engineering platform qualification artifacts

- Status: Accepted
- Date: 2026-10-27

## Context

P0–P9 provide increasingly capable analyses, design studies, validation, and
restartable batch execution. They do not yet answer a release-oriented question:
which controlled project revision was solved, which engineering limits applied,
and did every required check pass? CSV and VTK outputs are useful numerical and
visual artifacts, but they are not a compact qualification record.

MeshLab owns project semantics, units, mesh provenance, engineering response
interpretation, and application workflows. Swift-NumericCore owns reusable
solver and optimization APIs, while Rust-NumericCore remains an implementation
and acceleration layer behind Swift-NumericCore. Engineering acceptance policy
therefore belongs in MeshLab and must not leak into either numerical core.

## Decision

1. Add schema-v9 engineering metadata: controlled identifier, revision, analyst,
   and free-form summary. Add optional limits for displacement, von Mises stress,
   temperature, first modal frequency, relative residual, and mesh quality, plus
   an explicit convergence requirement.
2. Add `EngineeringAssessment`, which runs the project's selected analysis and
   reduces its results into a common response summary. It supports static,
   production-linear, nonlinear-static, coupled thermo-mechanical, modal, and
   thermal-structural projects.
3. A configured requirement that the selected analysis cannot evaluate is
   `not-evaluated` and causes the overall artifact to fail. Missing data must not
   be interpreted as compliance.
4. Inverted elements always fail qualification. Other mesh-quality acceptance
   is controlled by the configured minimum.
5. Emit a versioned `EngineeringRunArtifact` containing project identity,
   schema, deterministic project fingerprint, selected analysis and solver,
   NumericCore contract, compact mesh provenance, response summary, checks, and
   overall status.
6. Exclude timestamps and host details from the canonical artifact. Identical
   controlled inputs should produce byte-stable sorted-key JSON suitable for
   source-control review and cross-version comparison.
7. Provide Markdown as a human review projection of the canonical artifact.
   Markdown is not an independent source of truth.
8. Add `MeshLabReport` as a headless CI entry point. Exit status 0 means checks
   pass, 1 means execution failed, and 2 means execution completed but the
   engineering decision is not passing.
9. Let the workbench edit core provenance, run qualification asynchronously,
   and display check status. Signature and approval workflows remain outside the
   application for this milestone.

## Consequences

- Analysis release becomes deterministic, scriptable, and reviewable without
  coupling engineering policy to solver implementations.
- A changed revision, material, mesh, load, requirement, solver, or display-
  persisted project field changes the project fingerprint. The fingerprint is
  a stale-artifact guard, not a cryptographic signature.
- The common result summary intentionally records extrema and convergence
  evidence rather than complete field data; CSV and VTK remain the detailed
  exchange artifacts.
- Running qualification performs the configured analysis. The workbench does
  not currently reuse an earlier in-memory solve because artifact generation
  must remain independently reproducible.
- Historical projects decode with empty provenance and conservative default
  convergence/residual requirements.

## Follow-up

- Add signed attestations, trusted timestamps, approval roles, and immutable
  content-addressed artifact storage when deployment identity exists.
- Add report templates and PDF rendering without changing the canonical JSON
  evidence model.
- Add explicit unit systems for requirement entry and presentation; current
  thresholds use the project's normalized solver units.
- Add field-result artifact references and baseline comparison policies for
  regulated verification workflows.
