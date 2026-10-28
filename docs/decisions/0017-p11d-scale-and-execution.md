# ADR 0017: P11D scale and execution

- Status: Accepted
- Date: 2026-10-28

## Context

MeshLab could execute requests concurrently and resume completed requests from
a prior result. Long jobs still had two operational weaknesses: progress was
only durable after the entire process returned, and distributing one job across
workers required external, potentially inconsistent request slicing. Results
also lacked a stable job identity and a timing-independent content identity.

The released NumericCore stack provides sparse direct and iterative numerical
building blocks, but it does not provide a distributed FEM runtime. P11D keeps
distribution at the coarse request boundary where projects are independent and
artifacts remain portable JSON.

## Decision

1. Give every sweep job a deterministic fingerprint over its ordered request
   definitions. Every result records that identity.
2. Assign requests to deterministic shards from their request fingerprints.
   Shards are disjoint, cover the complete job, and remain stable across
   scheduling order and process lifetime.
3. Publish an ordered partial `SweepCheckpoint` after each completed request.
   The CLI writes these snapshots atomically, so interruption leaves either the
   prior complete checkpoint or the new one—never a partially written file.
4. Merge shard results only when their job identities and request fingerprints
   match. Reject foreign, duplicate, and missing requests, then restore original
   job order.
5. Compute a deterministic artifact ID from ordered numerical outcomes while
   excluding wall-clock duration and shard placement. Equivalent executions
   therefore converge on the same content identity.
6. Extend `MeshLabSweep` with `--checkpoint`, `--shard-index`, `--shard-count`,
   and repeatable `--merge-result` options. Existing unsharded and resume flows
   remain source- and file-compatible.

## Consequences

Jobs can now be safely divided among independent local or remote workers,
checkpointed during execution, resumed from partial output, and merged with
fail-closed identity checks. The protocol is storage-agnostic and needs no
coordinator service.

Checkpoints occur at request boundaries, not inside nonlinear, transient, or
optimization iterations. Artifact IDs use the existing dependency-free stable
identity hash and are integrity guards rather than cryptographic signatures.
Remote leases, content-addressed object-store transport, per-iteration restart,
GPU execution, and distributed sparse solves remain future work.
