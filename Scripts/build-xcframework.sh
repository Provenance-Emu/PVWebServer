#!/usr/bin/env bash
set -euo pipefail

output="${1:-dist}"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
cd "${2:-$(dirname "$0")/..}"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

framework_args=()
for platform in 'iOS' 'iOS Simulator' 'tvOS' 'tvOS Simulator' \
    'watchOS' 'watchOS Simulator' 'visionOS' 'visionOS Simulator' \
    'macOS' 'macOS,variant=Mac Catalyst'; do
    slice="$scratch/${platform//[^a-zA-Z]/_}"
    xcodebuild archive -quiet -scheme PVWebServer-Dynamic \
        -destination "generic/platform=$platform" \
        -archivePath "$slice/archive" -derivedDataPath "$slice/derived" \
        SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO PRODUCT_NAME=PVWebServer

    # Swift finds the module by framework name. PRODUCT_NAME also renames
    # the built resource bundle, so install it under Bundle.module's name.
    framework="$(find "$slice/archive.xcarchive/Products" -name PVWebServer.framework -print -quit)"
    products="$slice/derived/Build/Intermediates.noindex/ArchiveIntermediates/PVWebServer-Dynamic/BuildProductsPath"
    module="$(find "$products" -name PVWebServer.swiftmodule -type d -print -quit)"
    bundle="$(find "$products" -name PVWebServer.bundle -print -quit)"
    test -n "$framework" && test -n "$module" && test -n "$bundle" || {
        echo "Missing framework, Swift module or resources for $platform" >&2
        exit 1
    }
    test -n "$(find "$module" -name '*.swiftinterface' -print -quit)"

    root="$framework"
    resources="$framework"
    if [[ -d "$framework/Versions/Current" ]]; then
        root="$framework/Versions/Current"
        resources="$root/Resources"
        ln -s Versions/Current/Modules "$framework/Modules"
    fi
    mkdir -p "$root/Modules"
    ditto "$module" "$root/Modules/PVWebServer.swiftmodule"
    ditto "$bundle" "$resources/PVWebServer_PVWebServer.bundle"
    framework_args+=(-framework "$framework")
    rm -rf "$slice/derived"
done

xcodebuild -create-xcframework "${framework_args[@]}" -output "$scratch/PVWebServer.xcframework"
ditto -c -k --keepParent "$scratch/PVWebServer.xcframework" "$output/PVWebServer.xcframework.zip"
swift package compute-checksum "$output/PVWebServer.xcframework.zip" \
    > "$output/PVWebServer.xcframework.zip.sha256"
