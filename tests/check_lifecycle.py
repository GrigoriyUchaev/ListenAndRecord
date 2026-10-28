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

process = subprocess.Popen(
    [sys.argv[1], "--lifecycle-selftest"],
    env=environment,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    text=True,
)
try:
    output, _ = process.communicate(timeout=240)
except subprocess.TimeoutExpired:
    # Capture the blocked thread before terminating the test process.
    sample = subprocess.run(
        ["/usr/bin/sample", str(process.pid), "1", "1"],
        capture_output=True, text=True, timeout=15,
    )
    process.kill()
    output, _ = process.communicate()
    print(output, flush=True)
    print(sample.stdout, flush=True)
    print(sample.stderr, file=sys.stderr, flush=True)
    raise SystemExit("Lifecycle check timed out; thread sample is printed above")
print(output)
for line in output.splitlines():
    if "LIFECYCLE ERROR:" in line:
        # Surface the actual failure in the Actions summary as well as the logs.
        escaped = line.replace("%", "%25").replace("\r", "%0D")
        print(f"::error::{escaped}")
if process.returncode != 0:
    print(f"::error::Lifecycle process exited with code {process.returncode}")
    raise SystemExit(f"Lifecycle check failed: exit code {process.returncode}")
if "LIFECYCLE: close/reopen passed; requesting normal quit" not in output:
    raise SystemExit("Lifecycle check did not finish its window checks")
if len(sys.argv) > 2 and "LIFECYCLE: transcription completed with cached model" not in output:
    raise SystemExit("Lifecycle check did not exercise the cached Whisper model")
print("Lifecycle check passed: window reopened 3 times; application exited normally")
