#!/usr/bin/env bash

set -euo pipefail

VERSION="1.13.1"
ARCHIVE_NAME="sherpa-onnx-v${VERSION}-ios.tar.bz2"
EXPECTED_SHA256="5117ae7c1fe3cd5068b4f1012981e0ebc639a40633d85db35dff2efef48d336b"
DOWNLOAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VERSION}/${ARCHIVE_NAME}"
VENDOR_DIRECTORY="${1:-Vendor}"

if [[ -d "$VENDOR_DIRECTORY/sherpa-onnx.xcframework" && -d "$VENDOR_DIRECTORY/onnxruntime.xcframework" ]]; then
  exit 0
fi

TEMPORARY_DIRECTORY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT
curl --fail --location --retry 3 --output "$TEMPORARY_DIRECTORY/$ARCHIVE_NAME" "$DOWNLOAD_URL"
echo "$EXPECTED_SHA256  $TEMPORARY_DIRECTORY/$ARCHIVE_NAME" | shasum -a 256 --check
tar -xjf "$TEMPORARY_DIRECTORY/$ARCHIVE_NAME" -C "$TEMPORARY_DIRECTORY"

ONNXRUNTIME_FRAMEWORK="$(find "$TEMPORARY_DIRECTORY/build-ios/ios-onnxruntime" \
  -mindepth 2 -maxdepth 2 -type d -name onnxruntime.xcframework -print -quit)"
if [[ -z "$ONNXRUNTIME_FRAMEWORK" ]]; then
  echo "onnxruntime.xcframework was not found in $ARCHIVE_NAME" >&2
  exit 1
fi

mkdir -p "$VENDOR_DIRECTORY"
rm -rf "$VENDOR_DIRECTORY/sherpa-onnx.xcframework" "$VENDOR_DIRECTORY/onnxruntime.xcframework"
cp -R "$TEMPORARY_DIRECTORY/build-ios/sherpa-onnx.xcframework" "$VENDOR_DIRECTORY/"
cp -R "$ONNXRUNTIME_FRAMEWORK" "$VENDOR_DIRECTORY/"
