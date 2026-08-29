#!/usr/bin/env bash
# Prints the newest libopenbimrl_jni.so from the Bazel cache (for LLDB solib paths).
set -euo pipefail
find "${HOME}/.cache/bazel" -path '*/openbimrl_native*/lib/libopenbimrl_jni.so' -type f 2>/dev/null \
    | xargs -r ls -t 2>/dev/null \
    | head -1
