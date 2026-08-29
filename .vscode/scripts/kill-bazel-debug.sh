#!/usr/bin/env bash
# Stops Bazel-backed JVM debug sessions started from VS Code preLaunchTasks.
set +e

pkill -f 'agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005' 2>/dev/null
pkill -f 'bazel test //:show_distances_test.*java_debug' 2>/dev/null
pkill -f 'bazel test //:engine_jni_smoke_test.*java_debug' 2>/dev/null
pkill -f 'show_distances_test.*ConsoleLauncher' 2>/dev/null
pkill -f 'engine_jni_smoke_test.*ConsoleLauncher' 2>/dev/null
pkill -f 'process-wrapper.*show_distances_test' 2>/dev/null
pkill -f 'process-wrapper.*engine_jni_smoke_test' 2>/dev/null

rm -f /tmp/openbimrl-jdwp.pid 2>/dev/null

exit 0
