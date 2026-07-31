## mutex.nim - Windows named-mutex guard for TRNSYS process launches.
##
## TRNSYS does not tolerate simultaneous TrnEXE launches; two instances
## started at the same time can crash each other. This module serialises
## launches across all processes on the machine via a single named kernel
## mutex, `Global\TRNRun_LaunchMutex`.
##
## The mutex is created (or opened, if it already exists) at module
## initialisation and lives for the lifetime of the process; an `OSError`
## is raised at import time if creation fails.
##
## Typical usage:
##
## ```nim
## withLock:
##   startProcess("TrnEXE64.exe", …)
## ```

import std/[os, winlean]

# ---------------------------------------------------------------------------
# Win32 API
# ---------------------------------------------------------------------------
proc createMutex(attributes: pointer; initialOwner: cint; name: WideCString): Handle
  {.importc: "CreateMutexW", stdcall, dynlib: "kernel32".}

proc waitForSingleObject(handle: Handle; milliseconds: uint32): uint32
  {.importc: "WaitForSingleObject", stdcall, dynlib: "kernel32".}

proc releaseMutex(mutex: Handle): cint
  {.importc: "ReleaseMutex", stdcall, dynlib: "kernel32".}

const
  INFINITE = 0xFFFFFFFF'u32
  WAIT_OBJECT_0 = 0x00000000'u32
  WAIT_ABANDONED = 0x00000080'u32

let lock = createMutex(nil, 0, newWideCString("Global\\TRNRun_LaunchMutex"))
if lock == 0:
  raiseOSError(osLastError(), "Failed to create or open TRNSYS launch mutex.")

# ---------------------------------------------------------------------------
# Acquire / Release
# ---------------------------------------------------------------------------
proc acquireLock*() =
  ## Blocks until the global TRNSYS launch mutex is acquired (warns if the previous holder died).
  let waitResult = waitForSingleObject(lock, INFINITE)
  if waitResult == WAIT_ABANDONED:
    stderr.writeLine "Warning: previous TRNSYS process did not exit cleanly. Proceeding anyway."
  elif waitResult != WAIT_OBJECT_0:
    raiseOSError(osLastError(), "Failed to acquire TRNSYS launch mutex.")

proc releaseLock*() =
  ## Releases the global TRNSYS launch mutex.
  discard releaseMutex(lock)

# ---------------------------------------------------------------------------
# Public Template
# ---------------------------------------------------------------------------
template withLock*(body: untyped) =
  ## Runs `body` while holding the global TRNSYS launch mutex.
  ##
  ## Acquires the machine-wide named mutex, executes the body, and always
  ## releases the mutex afterwards - including when the body raises.
  ##
  ## Parameters
  ## ----------
  ## body : untyped
  ##     Statements to execute while the lock is held.
  ##
  ## Raises
  ## ------
  ## OSError
  ##     If the mutex cannot be acquired.
  acquireLock()
  try:
    body
  finally:
    releaseLock()
