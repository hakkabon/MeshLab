#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
resolved="$root/Package.resolved"
source_file="$root/Sources/MeshLabCore/Project/NumericStackProvenance.swift"

swift_version=$(sed -n '/"identity" : "swift-numericcore"/,/}/s/.*"version" : "\([^"]*\)".*/\1/p' "$resolved")
declared_swift=$(sed -n 's/.*static let swiftNumericCoreVersion = "\([^"]*\)".*/\1/p' "$source_file")

if [ -z "$swift_version" ] || [ "$swift_version" != "$declared_swift" ]; then
    echo "NumericCore provenance mismatch: Package.resolved=$swift_version source=$declared_swift" >&2
    exit 1
fi

echo "Numeric stack provenance matches Swift-NumericCore $swift_version."
