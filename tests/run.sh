#!/usr/bin/env bash
set -euo pipefail

lake build leanhttp_tests async_tests loader_failure
./.lake/build/bin/leanhttp_tests
./.lake/build/bin/async_tests
LEANHTTP_LIB=/definitely/not/a/libcurl.dylib ./.lake/build/bin/loader_failure
