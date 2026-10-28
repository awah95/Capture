#!/bin/bash

# Download the pinned Moonshine native runtime required to build Captur.
# This script only writes the generated library and its matching public header.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO}/Vendor/Moonshine"
LIB_PATH="${VENDOR_DIR}/lib/libmoonshine.a"
HEADER_PATH="${VENDOR_DIR}/include/moonshine-c-api.h"

VERSION="0.1.5"
ARCHIVE_URL="https://github.com/moonshine-ai/moonshine-swift/releases/download/v${VERSION}/Moonshine.xcframework.zip"
ARCHIVE_SHA256="6bc7fb4b6d3a470a2ae2d681299975f3ba9d710753786d1cd7e8beabaad066e8"
LIB_SHA256="f35a8229c8c67ddb4982f1a5a8765ae93377d42f7ecaf4bbbc17547665abccbb"
HEADER_SHA256="e5c9038c4987d87f40abd78f843bd6ab0bff96a5ffd1cc2557c5531b0cbab21f"

LIB_MEMBER="Moonshine.xcframework/macos-arm64_x86_64/libmoonshine.a"
HEADER_MEMBER="Moonshine.xcframework/macos-arm64_x86_64/Headers/moonshine-c-api.h"

sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

is_expected_file() {
    local path="$1"
    local expected="$2"
    [[ -f "$path" && ! -L "$path" && "$(sha256 "$path")" == "$expected" ]]
}

if is_expected_file "$LIB_PATH" "$LIB_SHA256" \
    && is_expected_file "$HEADER_PATH" "$HEADER_SHA256"; then
    echo "Moonshine ${VERSION} is already installed and verified."
    exit 0
fi

for command_name in curl unzip shasum awk mktemp; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "Missing required command: ${command_name}" >&2
        exit 1
    }
done

mkdir -p "$VENDOR_DIR"
TEMP_DIR="$(mktemp -d "${VENDOR_DIR}/.bootstrap.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT

ARCHIVE_PATH="${TEMP_DIR}/Moonshine.xcframework.zip"
STAGE_DIR="${TEMP_DIR}/stage"

echo "Downloading Moonshine ${VERSION}..."
curl --fail --location --silent --show-error --retry 3 --output "$ARCHIVE_PATH" "$ARCHIVE_URL"

actual_archive_sha="$(sha256 "$ARCHIVE_PATH")"
if [[ "$actual_archive_sha" != "$ARCHIVE_SHA256" ]]; then
    echo "Moonshine archive checksum mismatch." >&2
    echo "Expected: ${ARCHIVE_SHA256}" >&2
    echo "Actual:   ${actual_archive_sha}" >&2
    exit 1
fi

mkdir -p "$STAGE_DIR"
unzip -q "$ARCHIVE_PATH" "$LIB_MEMBER" "$HEADER_MEMBER" -d "$STAGE_DIR"

STAGED_LIB="${STAGE_DIR}/${LIB_MEMBER}"
STAGED_HEADER="${STAGE_DIR}/${HEADER_MEMBER}"

actual_lib_sha="$(sha256 "$STAGED_LIB")"
actual_header_sha="$(sha256 "$STAGED_HEADER")"
if [[ "$actual_lib_sha" != "$LIB_SHA256" ]]; then
    echo "Moonshine library checksum mismatch after extraction." >&2
    echo "Expected: ${LIB_SHA256}" >&2
    echo "Actual:   ${actual_lib_sha}" >&2
    exit 1
fi
if [[ "$actual_header_sha" != "$HEADER_SHA256" ]]; then
    echo "Moonshine header checksum mismatch after extraction." >&2
    echo "Expected: ${HEADER_SHA256}" >&2
    echo "Actual:   ${actual_header_sha}" >&2
    exit 1
fi

mkdir -p "$(dirname "$LIB_PATH")" "$(dirname "$HEADER_PATH")"

if ! is_expected_file "$LIB_PATH" "$LIB_SHA256"; then
    if [[ -e "$LIB_PATH" || -L "$LIB_PATH" ]] && [[ ! -f "$LIB_PATH" || -L "$LIB_PATH" ]]; then
        echo "Refusing to replace non-regular path: ${LIB_PATH}" >&2
        exit 1
    fi
    mv -f "$STAGED_LIB" "$LIB_PATH"
    chmod 0644 "$LIB_PATH"
fi

if ! is_expected_file "$HEADER_PATH" "$HEADER_SHA256"; then
    if [[ -e "$HEADER_PATH" || -L "$HEADER_PATH" ]] && [[ ! -f "$HEADER_PATH" || -L "$HEADER_PATH" ]]; then
        echo "Refusing to replace non-regular path: ${HEADER_PATH}" >&2
        exit 1
    fi
    mv -f "$STAGED_HEADER" "$HEADER_PATH"
    chmod 0644 "$HEADER_PATH"
fi

echo "Moonshine ${VERSION} installed and verified."
echo "The tracked module map at Vendor/Moonshine/include/module.modulemap was preserved."
