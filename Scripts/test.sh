#!/bin/bash
# Runs the test suite.
#
# Two flags this needs that a plain `swift test` does not give you, both of
# which fail with errors that name the wrong cause:
#
#   --disable-sandbox   SPM runs macro plugins sandboxed; swift-testing is
#                       macro-based and the sandbox denies what it needs.
#
#   -plugin-path        libTestingMacros.dylib ships in a `testing/`
#                       subdirectory of the toolchain's plugin folder, which is
#                       not on the default search path. Without it every @Test
#                       and #expect fails to expand with "plugin for module
#                       'TestingMacros' not found" — which reads like a missing
#                       dependency and is not one.
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=(--disable-sandbox)
PLUGINS="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$PLUGINS" ]; then
  ARGS+=(-Xswiftc -plugin-path -Xswiftc "$(cd "$PLUGINS" && pwd)")
fi

exec swift test "${ARGS[@]}" "$@"
