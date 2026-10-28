"""Run the macOS window close/reopen/normal-quit regression check.

The app must both exercise its window and exit normally: a crash, a missing
callback, or a stuck process fails this check.
"""
import subprocess
import sys

result = subprocess.run(
    [sys.argv[1], "--lifecycle-selftest"],
    capture_output=True,
    text=True,
    timeout=60,
)
print(result.stdout)
print(result.stderr, file=sys.stderr)
if result.returncode != 0:
    raise SystemExit(f"Lifecycle check failed: exit code {result.returncode}")
if "LIFECYCLE: close/reopen passed; requesting normal quit" not in result.stdout:
    raise SystemExit("Lifecycle check did not finish its window checks")
print("Lifecycle check passed: window reopened 3 times; application exited normally")
