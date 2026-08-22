## Non-destructive waiting for a Windows process to exit.
##
## Nim's Windows `Process.waitForExit(timeout)` terminates the process when the
## timeout expires. `waitForExitNonDestructive` instead waits through a separate
## synchronization handle, leaving the observed process untouched.

when not defined(windows):
  {.error: "processwait.nim is Windows-only.".}

import std/[oserrors, osproc, winlean]

proc waitForExitNonDestructive*(process: Process, timeoutMs: int): bool =
  ## Returns true if `process` exits within `timeoutMs`, without terminating it.
  ##
  ## `timeoutMs = 0` polls and returns immediately, following the Win32
  ## `WaitForSingleObject` convention. Callers above this layer - `wait.poll`,
  ## `waitReady`, the monitor timeouts - use `0` to mean "no limit" instead.
  if timeoutMs < 0:
    raise newException(ValueError, "timeoutMs must be non-negative")

  # Load-bearing, not a fast path: osproc sets `exitFlag` before releasing
  # `fProcessHandle` (and zeroes it in `close`), so `running` is always false
  # once the PID becomes recyclable. Returning here is what keeps the
  # `openProcess` below from ever latching onto a reused PID.
  if not process.running:
    return true

  let handle = openProcess(
    DWORD(SYNCHRONIZE),
    WINBOOL(0),
    DWORD(process.processID()),
  )
  if handle == 0:
    # The process may have exited between the running check and OpenProcess.
    if not process.running:
      return true
    raiseOSError(osLastError(), "Failed to open process synchronization handle.")
  defer:
    discard closeHandle(handle)

  let waitResult = waitForSingleObject(
    handle,
    min(timeoutMs, high(int32).int).int32,
  )
  if waitResult == WAIT_FAILED:
    raiseOSError(osLastError(), "Failed while waiting for process exit.")

  return waitResult == WAIT_OBJECT_0
