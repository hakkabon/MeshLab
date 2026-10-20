# Benchmark baselines

Committed benchmark results are snapshots, not regression gates. They exist to
make performance changes visible and to give future optimization work a
reference point.

The file name records the environment, for example:

```
macos-15.7.4-x86_64.json
```

Each file is produced with:

```bash
swift run -c release MeshLabBenchmarks --json --iterations 5 \
  > Benchmarks/baselines/$(sw_vers -productVersion)-$(uname -m).json
```

The JSON report includes the platform, architecture, build configuration,
mesh size, solver, and per-benchmark minimum/median/maximum timings. Record a new
baseline when the hardware, toolchain, or benchmark definition changes. Do not
overwrite an existing baseline to hide a regression; add a new environment file
or explain the change in the commit.

The current baseline was captured on an Intel iMac with a discrete GPU. It is
not representative of Apple Silicon unified-memory performance.
