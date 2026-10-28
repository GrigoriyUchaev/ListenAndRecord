"""Run the macOS window close/reopen/normal-quit regression check.

The app must both exercise its window and exit normally: a crash, a missing
callback, or a stuck process fails this check.
"""
import subprocess
import sys
import os

if len(sys.argv) not in (2, 4):
    raise SystemExit("Usage: check_lifecycle.py <app executable> [model audio]")
environment = os.environ.copy()
if len(sys.argv) == 4:
    # Cocoa interprets positional file arguments as document-open requests,
    # which can suppress the app's normal initial window presentation.
    environment["LISTENANDRECORD_LIFECYCLE_MODEL"] = os.path.abspath(sys.argv[2])
    environment["LISTENANDRECORD_LIFECYCLE_AUDIO"] = os.path.abspath(sys.argv[3])

result = subprocess.run(
    [sys.argv[1], "--lifecycle-selftest"],
    env=environment,
    capture_output=True,
    text=True,
    timeout=240,
)
print(result.stdout)
print(result.stderr, file=sys.stderr)
for line in (result.stdout + "\n" + result.stderr).splitlines():
    if "LIFECYCLE ERROR:" in line:
        # Surface the actual failure in the Actions summary as well as the logs.
        escaped = line.replace("%", "%25").replace("\r", "%0D")
        print(f"::error::{escaped}")
if result.returncode != 0:
    print(f"::error::Lifecycle process exited with code {result.returncode}")
    raise SystemExit(f"Lifecycle check failed: exit code {result.returncode}")
if "LIFECYCLE: close/reopen passed; requesting normal quit" not in result.stdout:
    raise SystemExit("Lifecycle check did not finish its window checks")
if len(sys.argv) > 2 and "LIFECYCLE: transcription completed with cached model" not in result.stdout:
    raise SystemExit("Lifecycle check did not exercise the cached Whisper model")
print("Lifecycle check passed: window reopened 3 times; application exited normally")
