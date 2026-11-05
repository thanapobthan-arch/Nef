#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [ -z "${NEFCOPY_TEST_HISTORY_DIRECTORY:-}" ]; then
  NEFCOPY_TEST_HISTORY_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/NefCopy-TestHistory.XXXXXX")"
  export NEFCOPY_TEST_HISTORY_DIRECTORY
fi
echo "NefCopy v21.1.4 — Vertical Queue Test Suite"
echo "=================================="
if ! command -v xcrun >/dev/null 2>&1; then echo "FAIL — Xcode command line tools not found"; exit 1; fi
if ! xcrun --find swift >/dev/null 2>&1; then echo "FAIL — Swift compiler not found"; exit 1; fi

echo "[1/4] Parsing production Swift sources..."
xcrun swiftc -parse Sources/NefCopy/*.swift
echo "PASS — Swift syntax"

echo "[2/4] Compiling production package..."
xcrun swift build
echo "PASS — Production package compiles"

echo "[3/4] Running XCTest reliability + safety regression suite..."
xcrun swift test
echo "PASS — XCTest"

echo "[4/4] Checking package metadata..."
xcrun swift package describe >/dev/null
echo "PASS — Package metadata"
echo
echo "ALL AUTOMATED TESTS PASSED"
echo "You can now run: ./build_dmg.sh"
