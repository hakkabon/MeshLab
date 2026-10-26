# MeshLab

MeshLab is an Apple-native finite-element analysis foundation and Metal viewer
in progress. It combines Swift geometry and 3D element assembly with the
NumericCore numerical stack and a real-time Metal renderer.

It provides linear-elastic static, modal, transient, and steady thermal
analysis of tetrahedral and triangular meshes, stress recovery, compliance
design studies, an interactive Metal viewport, and a SwiftUI product slice for
opening, solving, optimizing, inspecting, and exporting projects on macOS, iOS,
and visionOS.

## Status

P0 (Stabilize) is complete:

- numerical ownership and dependency policies are recorded as ADRs;
- CI builds debug and release configurations and runs the test suite;
- a scheduled NumericCore canary checks compatibility with 1.x updates;
- a benchmark executable records assembly, solve, and scene-building baselines;
- the repository layout, build commands, and current limitations are documented.

P1 (Unify numerics) is complete:

- `SparseSolver` is a facade over reusable `NumericCoreSparse` LU and LDLT
  factorizations, with symbolic reuse through `refactor(with:)`;
- direct settings expose ordering, pivot/drop tolerances, and refinement;
- solve reports expose backward error, refinement steps, factor nonzeros, and
  LDLT inertia;
- 3D patch and cantilever cases compare Accelerate and NumericCore backends;
- ownership boundaries stay explicit: FEM assembly owns the symmetric lower-CSR
  format, and the facade expands it for NumericCore.

P2 (Product slice) is complete:

- `MeshLabApp` provides a SwiftUI workbench with material, load, solver, and
  display controls;
- versioned JSON projects round-trip through import/export, and nodal results
  export as CSV;
- solves run asynchronously and report progress, errors, and timings;
- clicking the deformed surface selects a source node for inspection;
- the viewport includes a stress colorbar matching the Metal heatmap.

P3 (Dynamics and multiphysics) is complete for 3D modal, transient, and
steady thermal-structural analysis:

- tet4/tri3 consistent mass matrices and 3D/2D steady-conduction matrices;
- constrained generalized modal analysis with mass-normalized mode shapes;
- average-acceleration Newmark transient dynamics with Rayleigh damping;
- steady thermal analysis with Dirichlet temperatures, nodal heat, volumetric
  heat generation, and element heat-flux recovery;
- one-way thermal-structural coupling through equivalent thermal loads and
  thermal-strain recovery;
- project schema v2 with analysis selection, modal display state, thermal
  study data, and automatic v1 migration;
- the workbench can switch between static, modal, and thermal-structural
  studies, inspect mode shapes, and export analysis-specific CSV fields.

P4 (Design loop) is complete:

- parametric sweeps of Young's modulus, Poisson ratio, thickness, and load
  scale, validated against static solves;
- self-adjoint compliance sensitivities for element stiffness, material, and
  load scaling;
- SIMP topology optimization with a volume equality constraint, sensitivity
  filtering, and NumericCore L-BFGS-B;
- discrete node-motion shape optimization with a volume constraint;
- project schema v3 with parametric, topology, and shape study settings, plus
  v1/v2 migration;
- asynchronous design studies in the workbench with result summaries and
  best-sample, topology, and shape field rendering.

P5 (Platform and scale) is complete:

- element-by-element matrix-free static solves with Jacobi-preconditioned
  conjugate gradients, including prescribed values and thermal-stress loading;
- matrix-free controls in the project schema and workbench, with the assembled
  direct solver retained as the default;
- reusable batch-sweep jobs with bounded concurrency, ordered summaries,
  structured per-request failures, and JSON job/result round trips;
- a `MeshLabSweep` command-line worker for local or cloud batch execution;
- project schema v4 with automatic v1/v2/v3 migration;
- a visionOS 1.0 package target that shares the SwiftUI workbench and
  UIKit/MetalKit viewport bridge.

P6 (Consolidation and interoperability) is complete:

- a public, solver-facing `FEMLinearOperator` contract separates element
  assembly from the current matrix-free CG implementation;
- ASCII Gmsh 2.2/4.1 import supports linear triangles and tetrahedra, explicit
  source units, and durable named physical regions;
- legacy ASCII VTK export carries mesh geometry, displacement, and nodal von
  Mises fields to external post-processors;
- project schema v5 persists mesh provenance, normalized units, and regions,
  while v1–v4 projects migrate with empty metadata;
- `MeshLabValidate` emits deterministic JSON covering the operator seam,
  assembled/matrix-free parity, and analytical thermal conduction.

The package has 74 tests covering vector/dense/sparse math, mesh topology and
surface extraction, linear-static FEM equilibrium, solver backends and
factorization reuse, modal/transient dynamics, thermal conduction and thermal
stress, parametric sweeps, compliance adjoints, topology/shape optimization,
matrix-free parity and convergence, batch-sweep scheduling and failure
reporting, Gmsh/VTK interchange, deterministic validation, project files and
schema migration, CSV export, camera math,
render-scene mapping, stress palettes, surface picking, and Metal pipeline
creation.

## Architecture

```
                  +----------------------+
                  | MeshLabApp (SwiftUI) |  project workflow, picking,
                  |                      |  colorbar, async solve/design
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |  MeshLabRender       |  Metal, camera, MTKView bridge
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |  MeshLabCore         |  geometry, 3D elements, assembly,
                  |                      |  design studies, results
                  +----------+-----------+
                             |
              +--------------+---------------+
              |                              |
    +---------v----------+        +----------v-----------+
    |  Swift-NumericCore |        |  Rust-NumericCore    |
    |  numerical API     |<------>|  portable compute    |
    |  sparse/opt/FEM    |  FFI   |  kernels and solvers |
    +--------------------+        +----------------------+
```

### Target responsibilities

| Target | Responsibility |
| --- | --- |
| `MeshLabCore` | Mesh types, structured generators, material models, element kinematics, global assembly, Dirichlet/load handling, static/modal/transient/thermal analysis, design studies and sensitivities, result fields, solver facade. |
| `MeshLabRender` | Surface extraction consumption, `RenderScene`, orbit camera, Metal pipeline, shared result buffers, `MTKView`/SwiftUI bridges. |
| `MeshLab` | Umbrella re-export of Core and Render. |
| `MeshLabApp` | SwiftUI workbench: project import/export, asynchronous solve and design studies, inspection, picking, and colorbar. |
| `MeshLabBenchmarks` | Release-mode timing harness for mesh generation, assembled and matrix-free solves, and render-scene construction. |
| `MeshLabSweep` | JSON batch-sweep worker with bounded parallelism for local or cloud execution. |

### Ownership boundary

MeshLab owns geometry, meshing, 3D element formulations, assembly, design-study
formulations, rendering, and application UX. NumericCore owns reusable numerical
algorithms, sparse factorization, iterative solvers, nonlinear methods,
optimization, and its own 2D/truss/continuum FEM models. MeshLab's design
studies adapt those kernels to its assembled models; the fixed-step structural
Newmark path is likewise a MeshLab adapter pending an upstream contribution
(ADR 0005). The public FEM operator seam makes the matrix-free adapter
replaceable when Swift-NumericCore exposes operator-based Krylov solvers.
Rust-NumericCore stays behind Swift-NumericCore; MeshLab never imports the
generated FFI bindings directly.

See [ADR 0001](docs/decisions/0001-numerical-ownership.md) for the full decision
and its consequences.

## Requirements

- Swift 6.1 or newer
- macOS 13+, iOS 16+, or visionOS 1+
- Xcode 16.4+ for the Metal toolchain and Apple SDKs

## Build and test

```bash
./Scripts/check-architecture.sh
swift build
swift test
swift build -c release
swift run MeshLabApp
swift run MeshLabSweep --help
swift run MeshLabValidate
```

The package resolves `Swift-NumericCore` 1.x from a released tag and commits
`Package.resolved` for reproducibility. See
[ADR 0002](docs/decisions/0002-dependency-and-release-policy.md).

## Batch sweeps

`MeshLabSweep` reads a `SweepJob` JSON document and writes a
`SweepBatchResult` JSON document. Each request carries a complete
`MeshLabProject` and selects either its configured analysis or its configured
design study. Requests run with bounded concurrency, results preserve request
order, and individual failures are returned as structured summaries without
aborting the batch. A job contains a name and a list of requests; each request
embeds a complete exported `MeshLabProject` and selects `analysis` or `design`.

```bash
swift run -c release MeshLabSweep sweep.json --output results.json --concurrency 8
swift run -c release MeshLabSweep - < sweep.json > results.json
```

The worker exits with status 1 when any request fails. It does not yet provide
cloud storage, authentication, resumable jobs, or platform-specific GPU
execution; those remain deployment-layer concerns.

## Benchmarks

The benchmark executable has no third-party dependencies beyond MeshLabCore:

```bash
swift run -c release MeshLabBenchmarks
swift run -c release MeshLabBenchmarks --quick
swift run -c release MeshLabBenchmarks --json
```

Record a new baseline after a deliberate hardware, toolchain, or algorithm
change:

```bash
swift run -c release MeshLabBenchmarks --json \
  > Benchmarks/baselines/$(uname -m)-$(sw_vers -productVersion).json
```

Benchmarks are recorded and reviewed; they do not fail CI because performance is
machine-dependent. The committed baseline under `Benchmarks/baselines/` identifies
the environment it was captured on.

## Current capabilities

### Analysis

- 4-node tetrahedral and 3-node triangular elements.
- Small-strain, linear-elastic, isotropic materials.
- Plane stress and plane strain with thickness.
- Nodal loads, uniform surface tractions, and body forces.
- Node/axis Dirichlet constraints with exact prescribed-value elimination.
- Reactions, strain energy, element stresses, and nodal von Mises averaging.
- Consistent-mass modal analysis with mass-normalized mode shapes and
  generalized residual/orthogonality diagnostics.
- Newmark transient dynamics with Rayleigh damping and load histories.
- Steady thermal conduction with nodal heat, volumetric heat, and element
  heat-flux recovery.
- One-way thermal-structural coupling with equivalent thermal loads and
  thermal-strain stress recovery.
- Parametric static sweeps with Cartesian axes and objective-based best-sample
  selection.
- Self-adjoint compliance sensitivities and finite-difference-checked gradients.
- SIMP topology optimization with volume control, filtering, and L-BFGS-B.
- Discrete shape optimization of selected node coordinates with volume control.
- Structured box and rectangle mesh generators.
- Boundary surface extraction with outward face normals and source-node mapping.
- Solver selection: Accelerate Cholesky/LDLT, NumericCore Cholesky/LU/LDLT,
  reusable NumericCore factorizations, and CG/BiCGSTAB/GMRES with diagnostics.
- Optional matrix-free static and thermal-stress solves using an
  element-by-element stiffness operator and Jacobi-preconditioned CG.
- Batch analyses and design studies through `SweepJob`, `SweepRunner`, and the
  `MeshLabSweep` JSON worker.
- ASCII Gmsh 2.2/4.1 import for first-order triangles/tetrahedra with explicit
  units and named physical regions; legacy ASCII VTK result export.
- Deterministic `MeshLabValidate` JSON for cross-version numerical checks.
- Solver diagnostics: backward error, refinement steps, factor nonzeros, and
  LDLT inertia; same-pattern numeric refactorization.
- Connectivity, unsupported-DOF, and free-DOF residual checks.

### Workbench

- SwiftUI app with a built-in cantilever example and editable material/loads.
- Static, modal, and thermal-structural study selection with mode-shape
  inspection and thermal boundary summary.
- Parametric, topology, and shape design studies with asynchronous runs,
  summaries, and best-sample/optimized-field rendering.
- Solver picker for Accelerate and NumericCore direct/iterative methods, plus
  a matrix-free CG path for static and thermal-structural studies.
- Versioned JSON project import/export (schema v5, v1–v4 migration), ASCII
  Gmsh mesh import, static/modal/thermal CSV, and legacy VTK result export.
- Asynchronous solve with progress, cancellation of stale results, and errors.
- Surface picking resolves the deformed hit point to a source node.
- Stress colorbar mirrors the Metal five-stop palette.

### Rendering

- Metal renderer with deformed geometry and stress heatmap.
- Two-sided lighting and a Z-up orbit camera.
- Mouse/trackpad and touch gestures for orbit, pan, and zoom.
- Shared `MTLBuffer`s with a direct field-update path.
- macOS `NSViewRepresentable` and iOS/visionOS `UIViewRepresentable` bridges.
- 120 FPS target; actual frame rate depends on the display and model size.

## Current limitations

- Modal analysis uses a dense LAPACK eigensolver, so memory and time grow
  cubically with the number of free DOFs.
- Modal and transient analyses require homogeneous Dirichlet constraints.
- Transient dynamics is a library API only; the workbench does not yet expose
  load histories or time animation.
- Thermal-structural coupling remains one-way and currently 3D-only.
  Plane-strain thermal stress needs a separate reduced constitutive treatment,
  and two-way coupling needs a coupled/transient governing formulation.
- Thermal analysis is steady-state only; convection and radiation are not
  implemented.
- No nonlinear statics, contact, buckling, or plasticity yet.
- Constant-strain `tet4`/`tri3` elements only; no `tet10`, `hex8`, shells, or
  beams.
- Mesh generation is structured; Gmsh can supply unstructured first-order
  meshes, but there is no CAD kernel, mesh repair, quality metric, or adaptivity.
- No document-based autosave or report generation yet.
- Gmsh import is ASCII-only and limited to linear `triangle3`/`tetrahedron4`;
  binary Gmsh, OBJ/STL/CAD, higher-order elements, and VTU/XDMF are not
  implemented. Project schema v5 files are not readable by older clients.
- Design optimization is limited to linear-static compliance with homogeneous
  Dirichlet constraints and no thermal loading.
- Topology optimization reports densities but does not render a density field;
  shape optimization moves nodes on one selected face and has no
  manufacturability constraints.
- Design studies do not yet offer per-iteration progress or design-result CSV
  export.
- Matrix-free solves use Jacobi-preconditioned CG and are limited to symmetric
  positive-definite static/thermal-stress systems; modal, transient, and
  topology solves still use assembled matrices.
- NumericCore's MPS backend is not yet usable, so no GPU numerical path is
  shipped. The matrix-free CPU path is the current scale-out option.
- Batch sweeps hold the full job and result set in memory and do not yet
  support resume, retries, artifact storage, or authentication.
- Rendering lacks clipping, vector glyphs, and time animation.
- Picking is CPU ray casting and will need a spatial index or GPU picking for
  very large surfaces.
- Shaders are compiled at runtime; there is no precompiled `.metallib` yet.
- iOS and visionOS are built from shared sources but are not yet covered by
  dedicated CI jobs. A visionOS runtime was not installed on the development
  host used for this change, so the visionOS target has source-level support
  but no CI or runtime validation yet.
- The benchmark baseline was captured on an Intel Mac with a discrete GPU, so
  it is not representative of Apple Silicon unified-memory performance.

## Repository layout

```
Sources/
  MeshLabCore/        math, mesh, static/dynamic/thermal FEM, design, project format
  MeshLabRender/      camera, renderer, SwiftUI bridges, MSL, picking, colorbar
  MeshLab/            umbrella module
  MeshLabApp/         SwiftUI workbench executable
  MeshLabSweep/       JSON batch-sweep command-line worker
  MeshLabValidate/    deterministic interoperability validation worker
Tests/
  MeshLabCoreTests/   math, mesh, FEM, design, and scale tests
  MeshLabRenderTests/ camera, scene, Metal pipeline tests
Benchmarks/
  MeshLabBenchmarks/  release-mode timing harness
  baselines/          committed environment-specific results
docs/
  decisions/          architecture decision records
Scripts/
  check-architecture.sh   dependency/import boundary checks
.github/
  workflows/          CI and dependency canary
```

## Roadmap

- **P0 — Stabilize:** ownership ADR, CI, benchmark baseline, repository hygiene.
- **P1 — Unify numerics (complete):** solver facade over NumericCoreSparse,
  3D validation suite, coarse-grained FFI usage.
- **P2 — Product slice (complete):** SwiftUI app, import/export, asynchronous
  solve, picking, colorbar.
- **P3 — Dynamics and multiphysics (complete):** 3D modal/transient, steady
  thermal, and one-way thermal-structural coupling.
- **P3b — Nonlinear and higher-order:** nonlinear statics, `tet10`/`hex8`
  elements, shells, and beams.
- **P4 — Design loop (complete):** parametric studies, adjoint sensitivities,
  shape and topology optimization.
- **P5 — Platform and scale (complete):** matrix-free CPU solves, cloud-ready
  batch sweeps and CLI, visionOS target support, and matrix-free
  thermal-structural coupling.
- **P6 — Consolidation and interoperability (complete):** public FEM operator
  seam, Gmsh/VTK interchange, schema-v5 mesh metadata, and deterministic
  validation artifacts.
- **P7 — GPU and advanced coupling:** Metal/MPS numerical paths, resumable
  cloud workers, and two-way multiphysics.

## Contributing

- Keep reusable numerical algorithms in NumericCore. MeshLab may keep
  analysis-specific adapters where NumericCore lacks an equivalent API, such as
  the fixed-step Newmark path in ADR 0005 and matrix-free CG in ADR 0007;
  contribute generalizable pieces upstream.
- Only `MeshLabCore` may depend on NumericCore products.
- Do not import `NCBindings` or generated UniFFI symbols outside the Swift
  package boundary.
- Add or update tests for behavior changes.
- Run `swift test`, `swift build -c release`, `./Scripts/check-architecture.sh`,
  and the benchmark harness before opening a change that affects analysis or
  rendering performance.
- Record architectural changes as ADRs.
