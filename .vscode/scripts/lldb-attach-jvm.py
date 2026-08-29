"""LLDB script: attach to the JVM recorded by bazel-java-debug-wrapper.sh."""
import os
import sys

import lldb

pid_file = os.environ.get("OPENBIMRL_JDWP_PID_FILE", "/tmp/openbimrl-jdwp.pid")

try:
    pid = int(open(pid_file).read().strip())
except (OSError, ValueError) as exc:
    print(f"Cannot read JVM PID from {pid_file}: {exc}", file=sys.stderr)
    sys.exit(1)

if not os.path.exists(f"/proc/{pid}"):
    print(f"JVM process {pid} is not running (stale {pid_file}?)", file=sys.stderr)
    sys.exit(1)

exe = os.readlink(f"/proc/{pid}/exe")
dbg = lldb.debugger
target = dbg.GetSelectedTarget()
if not target.IsValid():
    target = dbg.CreateTarget(exe)
err = lldb.SBError()
target.AttachToProcessWithID(dbg.GetListener(), pid, err)
if err.Fail():
    scope = open("/proc/sys/kernel/yama/ptrace_scope").read().strip()
    raise RuntimeError(
        f"LLDB attach to pid {pid} failed: {err}. "
        f"kernel.yama.ptrace_scope={scope} (need 0 on the host). "
        "Set boot.kernel.sysctl.\"kernel.yama.ptrace_scope\" = 0 in NixOS and rebuild."
    )
