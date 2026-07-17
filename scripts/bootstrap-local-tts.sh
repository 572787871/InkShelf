#!/usr/bin/env bash
set -euo pipefail

VERSION="1.13.4"
ARCHIVE_NAME="sherpa-onnx-v${VERSION}-ios.tar.bz2"
ARCHIVE_SHA256="596f33bff80046a52144745745fe54d55e8b23659d92209f5ab7d94c1259fe6d"
DOWNLOAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE_NAME}"
REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIRECTORY="$REPOSITORY_ROOT/Vendor"

if [[ -d "$VENDOR_DIRECTORY/sherpa-onnx.xcframework" && -d "$VENDOR_DIRECTORY/onnxruntime.xcframework" ]]; then
  exit 0
fi

TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT

curl --fail --location --retry 3 --output "$TEMPORARY_DIRECTORY/$ARCHIVE_NAME" "$DOWNLOAD_URL"
printf '%s  %s\n' "$ARCHIVE_SHA256" "$TEMPORARY_DIRECTORY/$ARCHIVE_NAME" | shasum -a 256 --check
tar -xjf "$TEMPORARY_DIRECTORY/$ARCHIVE_NAME" -C "$TEMPORARY_DIRECTORY"

mkdir -p "$VENDOR_DIRECTORY"
rm -rf "$VENDOR_DIRECTORY/sherpa-onnx.xcframework" "$VENDOR_DIRECTORY/onnxruntime.xcframework"
cp -R "$TEMPORARY_DIRECTORY/build-ios/sherpa-onnx.xcframework" "$VENDOR_DIRECTORY/sherpa-onnx.xcframework"
cp -R "$TEMPORARY_DIRECTORY/build-ios/ios-onnxruntime/1.27.0/onnxruntime.xcframework" "$VENDOR_DIRECTORY/onnxruntime.xcframework"
