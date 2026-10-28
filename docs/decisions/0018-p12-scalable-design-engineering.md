# ADR 0018: P12 scalable design engineering

- Status: Accepted
- Date: 2026-10-28

## Context

MeshLab supported deterministic parametric exploration and nominal compliance
optimization. Engineering decisions still treated loads and stiffness as exact,
and large candidate/scenario sets had no direct connection to P11D's shard,
checkpoint, merge, and artifact contracts.

Reusable probability distributions, surrogate optimizers, and sampling
algorithms belong in NumericCore. MeshLab owns the engineering interpretation
of response limits, reliability, uncertainty scenarios, and analysis artifacts.

## Decision

1. Add robust parametric design as a fourth design-study kind. A study combines
   discrete design axes with weighted load and Young's-modulus uncertainty
   scenarios.
2. Expand every candidate/scenario pair into an ordinary analysis-only
   `SweepRequest`. The resulting job can execute locally or through P11D shards,
   atomic checkpoints, resume, and fail-closed merging.
3. Reduce successful artifacts into weighted mean, population standard
   deviation, and worst-case compliance, displacement, and von Mises stress.
4. Define the robust scalar objective as `mean + variabilityWeight * sigma`.
   Hard engineering response limits are evaluated per scenario; candidate
   reliability is the total passing scenario weight divided by total weight.
5. Select only candidates meeting the configured minimum reliability. Report a
   deterministic non-dominated set over the three mean response metrics.
6. Persist robust studies in project schema v14. Export candidate values,
   reliability, robust objective, and all aggregate metrics as CSV; expose the
   study and result summary in the workbench and batch worker.
7. Bound one study at 16,384 analyses and require positive, uniquely identified
   scenarios. Failed or mismatched scenario artifacts fail the reduction rather
   than silently biasing statistics.

## Consequences

MeshLab can now make traceable design decisions under discrete engineering
uncertainty and distribute the expensive scenario ensemble without creating a
second execution protocol. Nominal topology and shape optimizers remain
unchanged and continue to use NumericCore L-BFGS-B.

P12 does not claim continuous probability distributions, correlated random
variables, surrogate-assisted optimization, FORM/SORM reliability, stochastic
gradients, or robust topology optimization. Those require stable cross-language
NumericCore contracts before they become production MeshLab capabilities.
