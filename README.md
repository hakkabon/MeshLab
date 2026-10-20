# MeshLab

MeshLab is an Apple-native finite-element analysis foundation and Metal viewer
in progress. It combines Swift geometry and 3D element assembly with the
NumericCore numerical stack and a real-time Metal renderer.

It provides linear-elastic static, modal, transient, and steady thermal
analysis of tetrahedral and triangular meshes, stress recovery, an interactive
Metal viewport, and a SwiftUI product slice for opening, solving, inspecting,
and exporting projects on macOS and iOS.

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

The package has 46 tests covering vector/dense/sparse math, mesh topology and
surface extraction, linear-static FEM equilibrium, solver backends and
factorization reuse, modal/transient dynamics, thermal conduction and thermal
stress, project files and schema migration, CSV export, camera math,
render-scene mapping, stress palettes, surface picking, and Metal pipeline
creation.

## Architecture

```
                  +----------------------+
                  | MeshLabApp (SwiftUI) |  project workflow, picking,
                  |                      |  colorbar, async solve
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |  MeshLabRender       |  Metal, camera, MTKView bridge
                  +----------+-----------+
                             |
                  +----------v-----------+
                  |  MeshLabCore         |  geometry, 3D elements, assembly,
                  |                      |  boundary conditions, results
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
| `MeshLabCore` | Mesh types, structured generators, material models, element kinematics, global assembly, Dirichlet/load handling, static/modal/transient/thermal analysis, result fields, solver facade. |
| `MeshLabRender` | Surface extraction consumption, `RenderScene`, orbit camera, Metal pipeline, shared result buffers, `MTKView`/SwiftUI bridges. |
| `MeshLab` | Umbrella re-export of Core and Render. |
| `MeshLabApp` | SwiftUI workbench: project import/export, asynchronous solve, inspection, picking, and colorbar. |
| `MeshLabBenchmarks` | Release-mode timing harness for mesh generation, assembly/solve, and render-scene construction. |

### Ownership boundary

MeshLab owns geometry, meshing, 3D element formulations, assembly, rendering,
and application UX. NumericCore owns reusable numerical algorithms, sparse
factorization, iterative solvers, nonlinear methods, optimization, and its own
2D/truss/continuum FEM models. The fixed-step structural Newmark path is
currently a MeshLab adapter pending an upstream contribution (ADR 0005).
Rust-NumericCore stays behind Swift-NumericCore; MeshLab never imports the
generated FFI bindings directly.

See [ADR 0001](docs/decisions/0001-numerical-ownership.md) for the full decision
and its consequences.

## Requirements

- Swift 6.1 or newer
- macOS 13+ or iOS 16+
- Xcode 16.4+ for the Metal toolchain and Apple SDKs

## Build and test

```bash
./Scripts/check-architecture.sh
swift build
swift test
swift build -c release
swift run MeshLabApp
```

The package resolves `Swift-NumericCore` 1.x from a released tag and commits
`Package.resolved` for reproducibility. See
[ADR 0002](docs/decisions/0002-dependency-and-release-policy.md).

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
- Structured box and rectangle mesh generators.
- Boundary surface extraction with outward face normals and source-node mapping.
- Solver selection: Accelerate Cholesky/LDLT, NumericCore Cholesky/LU/LDLT,
  reusable NumericCore factorizations, and CG/BiCGSTAB/GMRES with diagnostics.
- Solver diagnostics: backward error, refinement steps, factor nonzeros, and
  LDLT inertia; same-pattern numeric refactorization.
- Connectivity, unsupported-DOF, and free-DOF residual checks.

### Workbench

- SwiftUI app with a built-in cantilever example and editable material/loads.
- Static, modal, and thermal-structural study selection with mode-shape
  inspection and thermal boundary summary.
- Solver picker for Accelerate and NumericCore direct/iterative methods.
- Versioned JSON project import/export (schema v2, v1 migration); static,
  modal, and thermal CSV result export.
- Asynchronous solve with progress, cancellation of stale results, and errors.
- Surface picking resolves the deformed hit point to a source node.
- Stress colorbar mirrors the Metal five-stop palette.

### Rendering

- Metal renderer with deformed geometry and stress heatmap.
- Two-sided lighting and a Z-up orbit camera.
- Mouse/trackpad and touch gestures for orbit, pan, and zoom.
- Shared `MTLBuffer`s with a direct field-update path.
- macOS `NSViewRepresentable` and iOS `UIViewRepresentable` bridges.
- 120 FPS target; actual frame rate depends on the display and model size.

## Current limitations

- Modal analysis uses a dense LAPACK eigensolver, so memory and time grow
  cubically with the number of free DOFs.
- Modal and transient analyses require homogeneous Dirichlet constraints.
- Transient dynamics is a library API only; the workbench does not yet expose
  load histories or time animation.
- Thermal-structural coupling is one-way and currently 3D-only. Plane-strain
  thermal stress needs a separate reduced constitutive treatment.
- Thermal analysis is steady-state only; convection and radiation are not
  implemented.
- No nonlinear statics, contact, buckling, or plasticity yet.
- Constant-strain `tet4`/`tri3` elements only; no `tet10`, `hex8`, shells, or
  beams.
- Structured meshes only; no CAD/mesh import, unstructured meshing, quality
  metrics, or adaptivity.
- No document-based autosave or report generation yet.
- Import is limited to MeshLab project JSON; OBJ/STL/CAD import is not
  implemented. Project schema v2 files are not readable by older v1 clients.
- Rendering lacks clipping, vector glyphs, and time animation.
- Picking is CPU ray casting and will need a spatial index or GPU picking for
  very large surfaces.
- Shaders are compiled at runtime; there is no precompiled `.metallib` yet.
- iOS is built from shared sources but is not yet covered by a dedicated CI job.
- The benchmark baseline was captured on an Intel Mac with a discrete GPU, so
  it is not representative of Apple Silicon unified-memory performance.

## Repository layout

```
Sources/
  MeshLabCore/        math, mesh, static/dynamic/thermal FEM, project format
  MeshLabRender/      camera, renderer, SwiftUI bridges, MSL, picking, colorbar
  MeshLab/            umbrella module
  MeshLabApp/         SwiftUI workbench executable
Tests/
  MeshLabCoreTests/   math, mesh, FEM tests
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
- **P4 — Design loop:** parametric studies, adjoint sensitivities, shape and
  topology optimization.
- **P5 — Platform and scale:** GPU/matrix-free paths, cloud sweeps, visionOS,
  multiphysics coupling.

## Contributing

- Keep reusable numerical algorithms in NumericCore. MeshLab may keep
  analysis-specific adapters where NumericCore lacks an equivalent API, such as
  the fixed-step Newmark path in ADR 0005; contribute generalizable pieces
  upstream.
- Only `MeshLabCore` may depend on NumericCore products.
- Do not import `NCBindings` or generated UniFFI symbols outside the Swift
  package boundary.
- Add or update tests for behavior changes.
- Run `swift test`, `swift build -c release`, `./Scripts/check-architecture.sh`,
  and the benchmark harness before opening a change that affects analysis or
  rendering performance.
- Record architectural changes as ADRs.
