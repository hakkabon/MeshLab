# 0004: Product workflow and project format

- Status: Accepted
- Date: 2026-10-20

## Context

P0 and P1 produced a tested library foundation, but the only user-facing entry
points were benchmarks and low-level viewport bridges. P2 needs a coherent
end-to-end slice: open a model, solve it, inspect the field, and take results
away. That requires durable document state, a long-running solve path, and
interaction with the rendered surface.

The product slice must not erode the ownership boundary from ADR 0001. The app
should consume MeshLab's public types, not reach into NumericCore or duplicate
solver logic.

## Decision

1. **A JSON project is the durable interchange format.** `MeshLabProject` owns
   the mesh, material, boundary conditions, loads, solver selection, direct
   settings, and display state. It carries a `schemaVersion`; future versions
   are rejected instead of being partially interpreted.
2. **The app only imports MeshLab projects and exports MeshLab projects or
   CSV results.** This is intentionally narrower than CAD/mesh interoperability.
   General mesh import remains a separate problem with its own validation and
   unit conventions.
3. **Decoding validates through the domain initializers.** `Mesh` and
   `ElasticMaterial` perform their normal construction validation during
   `Codable` decoding, so malformed files cannot bypass degeneracy, index, or
   material checks.
4. **Solving runs off the main actor.** The app starts a detached task for the
   synchronous `StaticAnalysis.solve` call, then returns the sendable
   `StaticResult` to the main-actor model. The UI exposes progress, errors, and
   cancellation of stale results.
5. **Picking is a CPU ray cast against the deformed surface.** Screen points are
   unprojected through the current `OrbitCamera`, intersected with the render
   triangles after applying the active deformation scale, and resolved to a
   source mesh node. This is deterministic, testable, and sufficient for the
   current mesh sizes. GPU picking can replace it later behind the same
   `SurfacePick` result.
6. **The stress legend mirrors the Metal palette.** `StressPalette` and the MSL
   `stressColor` function share the same five stops. The SwiftUI legend is a
   product surface over the renderer, not a second colormap implementation with
   independent stops.
7. **The app target is an executable consumer of the umbrella module.** It
   imports `MeshLab`, not `MeshLabCore` internals or NumericCore. The library
   targets remain usable without SwiftUI or app state.

## Consequences

- Projects are inspectable, diffable, and easy to validate in tests.
- Opening a project restores both the analysis definition and the review state.
- Solves no longer block window interaction, and a new solve supersedes stale
  results.
- Picking and legends are available on every platform where the viewport is
  compiled, without changing the renderer's data flow.
- The project format needs deliberate migrations once the schema changes.
- CSV is a review/interchange format, not a complete restartable document.
- The mirrored stress palette must be updated in Swift and Metal together.

## Alternatives considered

- **Use an Xcode app project instead of a SwiftPM executable.** Rejected for
  now. The package already builds and tests the libraries; a SwiftPM executable
  keeps CI and local workflows simple.
- **Use a binary document format.** Rejected. JSON is visible in review, easy to
  test, and adequate for the current mesh sizes.
- **Import OBJ/STL directly in the app.** Rejected for P2. It would introduce
  unit, weld, orientation, and boundary-condition questions before the product
  loop itself is proven.
- **Solve synchronously.** Rejected. Even small 3D meshes can stall the UI, and
  the existing analysis API is synchronous by design.
- **GPU picking via an ID pass.** Rejected for the first slice. CPU ray casting
  is simpler, deterministic, and testable; the renderer should remain focused on
  visualization until scale demands otherwise.

## Follow-ups

- Add document autosave and project schema migrations.
- Add OBJ/STL import with explicit units and mesh repair.
- Add GPU picking or a spatial index for large surfaces.
- Add colorbar range controls and multiple field quantities.
- Precompile the Metal shader library for app distribution.
