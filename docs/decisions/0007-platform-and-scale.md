# 0007: Platform and scale — matrix-free solves, batch sweeps, and visionOS

- Status: Accepted
- Date: 2026-10-21

## Context

P0–P4 delivered a tested analysis stack, design loop, versioned project format,
and a SwiftUI workbench. P5 addresses three scale and platform constraints:

- assembled sparse factorization becomes the dominant memory cost for larger
  static models;
- design studies and parameter searches need a format that can run outside the
  app, with bounded parallelism and machine-readable results;
- the workbench and Metal viewport should build for visionOS without forking
  the application.

NumericCore 1.0 exposes sparse factorizations, iterative solvers, and
optimization, but no public matrix-free linear CG over a user-supplied
operator. Its MPS numerical backend is still a scaffold and is not a viable GPU
path for this release.

## Decision

1. **Matrix-free static solves use an element-by-element operator.**
   `StaticAnalysis` can build an `ElementStiffnessOperator` instead of a global
   sparse matrix. Each product assembles element stiffness contributions
   directly into the global result. Prescribed values are eliminated exactly by
   subtracting `K u_p` from the free right-hand side.
2. **Matrix-free CG is an explicit MeshLab adapter.**
   The solver uses Jacobi-preconditioned conjugate gradients and returns the
   existing `SparseSolveReport` shape with iteration and residual diagnostics.
   It is documented as a temporary structural adapter because NumericCore does
   not yet expose this abstraction. Generalizable pieces should move upstream
   under the ADR 0001 ownership policy.
3. **Matrix-free settings travel with the project.**
   `MatrixFreeOptions` stores maximum iterations, relative tolerance, and the
   Jacobi switch. `MatrixFreeOptions` is optional in `AnalysisOptions`, so
   assembled solves remain the default. Project schema advances to v4; v1–v3
   projects decode with matrix-free disabled and default options.
4. **The matrix-free path serves thermal-structural coupling too.**
   Thermal-stress recovery delegates to the same static solve, so it inherits
   the element-by-element path without a second formulation. Modal, transient,
   and topology optimization continue to use assembled matrices.
5. **Batch sweeps are reusable library values.**
   `SweepJob` contains named `SweepRequest`s; each request carries a complete
   project and selects analysis or design execution. `SweepRunner` executes with
   bounded task-group concurrency, returns summaries in request order, and
   converts individual errors into structured `failed` summaries instead of
   aborting the batch.
6. **The CLI is a thin worker around the library.**
   `MeshLabSweep` reads a job from a file or standard input, writes a JSON
   result, and returns a non-zero status when any request fails. Transport,
   authentication, retries, and artifact storage stay outside the numerical
   package. Jobs and results use the same `Codable` types as library callers.
7. **visionOS shares the existing UI and renderer.**
   The package declares visionOS 1.0 and routes the viewport through the
   existing UIKit `UIViewRepresentable` path, sharing gesture handling and the
   MetalKit renderer with iOS. No visionOS-only scene or compositor is
   introduced.
8. **GPU execution is not claimed in P5.**
   The matrix-free CPU path is the shipped scale-out mechanism. A Metal/MPS
   numerical backend remains a follow-up until NumericCore exposes a usable
   API or MeshLab owns a maintainable Metal implementation.

## Validation

- Matrix-free static displacement, strain energy, and peak stress match the
  assembled solve on the cantilever example.
- Prescribed nonzero values and thermal-stress loading match the assembled
  path within tight relative tolerances.
- Sweep execution preserves request order under concurrency, reports failures
  without dropping successful requests, and round-trips jobs and results
  through JSON.
- Project v3 documents without matrix-free fields decode with defaults; v4
  projects round-trip matrix-free settings.
- The full suite passes with 64 tests.
- Debug, release, architecture, and benchmark smoke checks pass on the
  development host.
- The visionOS conditional source path is present, but the host had no
  visionOS simulator runtime and no cross-build succeeded; compile and runtime
  validation remain outstanding.

## Consequences

- Matrix-free products still store one dense element stiffness matrix per
  element and a displacement-sized work vector. The win is avoiding the global
  sparse factorization and its fill, not eliminating element storage.
- Matrix-free CG assumes a symmetric positive-definite free system. It is not a
  general replacement for the direct solver and does not accelerate modal,
  transient, or optimization paths yet.
- Batch workers are stateless and in-memory. Large cloud jobs need an external
  queue, storage, and retry layer.
- visionOS support is source-level and shares iOS gesture semantics; spatial
  input affordances and dedicated scene layout are follow-ups.
- Thermal-structural coupling remains one-way. P5 makes that path matrix-free
  and sweepable, but does not add a two-way coupled formulation.

## Follow-ups

- Move matrix-free CG and operator protocols to NumericCore once a stable API
  is available.
- Add a Metal/MPS or CPU-parallel numerical backend with benchmarks against the
  current CG path.
- Add resumable cloud jobs, request-level retries, artifact storage, and
  progress callbacks.
- Validate the visionOS target in CI and add spatial-input-specific controls.
- Add two-way and transient multiphysics coupling with a coupled governing
  formulation.
