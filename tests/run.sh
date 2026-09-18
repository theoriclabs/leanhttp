#!/usr/bin/env bash
set -euo pipefail

lake build leanhttp_tests async_tests loader_failure ws_tests
./.lake/build/bin/leanhttp_tests
./.lake/build/bin/async_tests
LEANHTTP_LIB=/definitely/not/a/libcurl.dylib ./.lake/build/bin/loader_failure
# Runs the round trips when the loaded libcurl has WebSocket support and
# checks the typed error when it does not. LEANHTTP_LIB selects the library.
./.lake/build/bin/ws_tests
