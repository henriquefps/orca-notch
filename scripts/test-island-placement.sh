#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/orca-notch-placement.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/NotchKit/IslandPlacement.swift \
    tests/IslandPlacementTests.swift -o "$TEST_DIR/placement-tests"
"$TEST_DIR/placement-tests"
