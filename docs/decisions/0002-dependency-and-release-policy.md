# 0002: NumericCore dependency and release policy

- Status: Accepted
- Date: 2026-10-20

## Context

`Swift-NumericCore` is not a small utility dependency. It is a numerical
platform with a public API, a binary XCFramework produced by
`Rust-NumericCore`, and an automated release pipeline that keeps Swift bindings
and Rust artifacts aligned. Its 1.x line is the compatibility boundary for
consumers.

MeshLab therefore needs a deliberate policy for dependency updates, reproducible
builds, and release compatibility. Floating branches or ad hoc local paths would
make failures difficult to reproduce and would hide FFI breakage until runtime.

## Decision

1. **Consume released tags only.** MeshLab depends on `Swift-NumericCore` via
   `.upToNextMajor(from: "1.0.0")`. It does not depend on `main`, a branch, a
   local path, or an unversioned binary.
2. **Commit `Package.resolved`.** Applications and CI build the same resolved
   graph. `Package.resolved` is part of the repository, not a generated file to
   ignore.
3. **Upgrade deliberately.** A NumericCore upgrade is its own change:
   - run `swift package update`;
   - read the Swift and Rust release notes and capability manifest;
   - run `swift test` and the release build;
   - run the benchmark suite and compare with the committed baseline;
   - commit the updated `Package.resolved` together with any required source
     adaptation.
4. **Run a dependency canary.** A scheduled workflow updates all dependencies
   and runs the test suite. It does not commit changes; it exists to surface
   1.x regressions early. Failures are investigated before the next deliberate
   upgrade.
5. **Respect the layering.** Only `MeshLabCore` may depend on NumericCore
   products. Rendering and application code consume MeshLab's own types. No
   target imports `NCBindings` or generated UniFFI symbols directly.
6. **Do not vendor the FFI artifact.** The binary target URL and checksum are
   owned by `Swift-NumericCore`'s release pipeline. MeshLab pins the Swift
   package and lets that package pin the Rust release.
7. **Release MeshLab semantically.** MeshLab stays on `0.x` while the
   application and public API are still forming. Once a `1.0` API is declared,
   it follows semantic versioning. Breaking changes require a major version.
8. **Benchmarks inform, tests gate.** Correctness, build, and test jobs gate
   merges. Benchmarks are recorded and compared, but machine variance means they
   do not fail CI automatically.

## Consequences

- Dependency updates are visible in review and reproducible in CI.
- A NumericCore 1.x change that breaks MeshLab is caught by the canary or by a
  deliberate upgrade, not by a surprising build on a user's machine.
- MeshLab can move quickly while keeping a stable, auditable numerical
  foundation.
- Keeping adapters thin is important: a wide MeshLab surface built directly on
  NumericCore internals would make minor upgrades expensive.

## Follow-ups

- Add a compatibility note to release tags when more than one NumericCore minor
  version is supported.
- Keep `Benchmarks/baselines/` current when hardware or toolchains change, and
  label baseline files with their environment.
- Revisit the `.upToNextMajor` policy if NumericCore begins shipping breaking
  changes within 1.x; a narrower range or exact pin would then be appropriate.
