#!/bin/bash
# Runs the test suite.
#
# --disable-sandbox is required, not optional: swift-testing is macro-based, and
# SPM runs macro plugins inside a sandbox that denies the plugin access it needs
# on macOS. Without this flag every @Test fails to expand with
# "plugin for module 'TestingMacros' not found", which reads like a missing
# dependency and is not one.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test --disable-sandbox "$@"
