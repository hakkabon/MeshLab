## Summary

Describe the change and the problem it solves.

## Checklist

- [ ] `swift build` passes
- [ ] `swift test` passes
- [ ] `swift build -c release` passes
- [ ] Numerical changes are covered by tests or reference cases
- [ ] No general numerical algorithm was duplicated from NumericCore
- [ ] Only `MeshLabCore` imports NumericCore products
- [ ] No direct `NCBindings` or generated UniFFI imports were introduced
- [ ] Benchmark impact was considered and measured for performance-sensitive changes
- [ ] Architectural changes are recorded in `docs/decisions/`

## Notes for reviewers

Call out API changes, dependency changes, or follow-up work.
