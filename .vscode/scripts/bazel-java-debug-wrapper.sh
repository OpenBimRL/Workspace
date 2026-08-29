#!/usr/bin/env bash
# Runs `bazel test … --java_debug`, records the suspended JVM PID, and prints the
# line VS Code waits on before attaching the Java debugger.
set -euo pipefail

PID_FILE="${OPENBIMRL_JDWP_PID_FILE:-/tmp/openbimrl-jdwp.pid}"
rm -f "$PID_FILE"

"$@" &
bazel_pid=$!

cleanup() {
    kill "$bazel_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Waiting for JVM debugger on port 5005..."
for _ in $(seq 1 1200); do
    jdwp_pid=$(
        pgrep -f 'agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005' 2>/dev/null | head -1 || true
    )
    if [[ -n "$jdwp_pid" ]]; then
        echo "$jdwp_pid" >"$PID_FILE"
        echo "Listening for transport dt_socket at address: 5005"
        echo "JVM debug PID: $jdwp_pid (native LLDB auto-attaches via $PID_FILE)"
        wait "$bazel_pid"
        exit $?
    fi
    if ! kill -0 "$bazel_pid" 2>/dev/null; then
        wait "$bazel_pid"
        exit $?
    fi
    sleep 0.25
done

echo "Timed out waiting for JDWP on port 5005" >&2
exit 1
