#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

failures=0

fail() {
    echo "error: $*" >&2
    failures=$((failures + 1))
}

if [[ ! -f Package.resolved ]]; then
    fail "Package.resolved is missing; commit the resolved dependency graph"
fi

if grep -n -E '\.branch\(' Package.swift >/dev/null 2>&1; then
    fail "Package.swift must depend on released tags, not branches"
fi

if grep -n -E '\.package\([[:space:]]*path:' Package.swift >/dev/null 2>&1; then
    fail "Package.swift must not depend on local package paths"
fi

direct_numeric_imports="$(
    grep -R --include='*.swift' -n -E \
        '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(NumericCore|NumericCoreSparse|NumericCoreAccelerate|NumericCoreOptimization|NumericCoreGraph|NumericCoreAMPL|NumericCoreMPS)' \
        Sources Tests Benchmarks 2>/dev/null \
        | grep -v '^Sources/MeshLabCore/' || true
)"
if [[ -n "$direct_numeric_imports" ]]; then
    fail "NumericCore imports are only allowed in MeshLabCore:"
    printf '%s\n' "$direct_numeric_imports" >&2
fi

ffi_imports="$(
    grep -R --include='*.swift' -n -E \
        '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+NCBindings' \
        Sources Tests Benchmarks 2>/dev/null || true
)"
if [[ -n "$ffi_imports" ]]; then
    fail "Direct NCBindings imports are not allowed:"
    printf '%s\n' "$ffi_imports" >&2
fi

if [[ "$failures" -ne 0 ]]; then
    echo "Architecture check failed with $failures issue(s)." >&2
    exit 1
fi

echo "Architecture and dependency boundaries are valid."
