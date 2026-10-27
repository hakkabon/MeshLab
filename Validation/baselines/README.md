# Numerical validation baselines

`standard.json` is the committed, deterministic MeshLab/NumericCore integration
corpus. CI runs the current standard suite and compares case identifiers,
metric identifiers, the exact NumericCore capability manifest, and observations
within each metric's declared tolerance.

Regenerate it only for a reviewed numerical-stack upgrade or an intentional
reference-result change:

```bash
swift run MeshLabValidate --write Validation/baselines/standard.json
```

Do not update the snapshot merely to make a regression pass. Explain numerical
changes and their verification evidence in the associated ADR or pull request.
