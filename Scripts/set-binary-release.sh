#!/usr/bin/env bash
# Points Package.swift at a release's prebuilt XCFramework. Run by the release
# workflow on the commit it tags; never commit the result to a branch.
set -euo pipefail

version="$1"
checksum="$2"
manifest="${3:-$(dirname "$0")/../Package.swift}"
unset_line='let binaryRelease: (version: String, checksum: String)? = nil'

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Bad version: $version" >&2; exit 1; }
[[ "$checksum" =~ ^[0-9a-f]{64}$ ]] || { echo "Bad checksum: $checksum" >&2; exit 1; }
[[ "$(grep -cFx "$unset_line" "$manifest")" == 1 ]] || {
    echo "$manifest: expected exactly one unset binaryRelease line" >&2
    exit 1
}

replacement="let binaryRelease: (version: String, checksum: String)? = (\"$version\", \"$checksum\")"
awk -v from="$unset_line" -v to="$replacement" '$0 == from { print to; next } { print }' \
    "$manifest" > "$manifest.tmp"
mv "$manifest.tmp" "$manifest"
