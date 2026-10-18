## Serializes TrnEXE launches across one Windows logon session.
##
## TRNSYS does not tolerate simultaneous launches, so every runner uses the
## named `Local\TRNRun_LaunchMutex`. Win32 mutex ownership is per thread:
## release must occur on the acquiring thread, and nested acquisition is safe.
##
## ```nim
## withLaunchLock:
##   startProcess("TrnEXE64.exe", …)
## ```

when not defined(windows):
  {.error: "mutex.nim is Windows-only.".}

import std/[locks, oserrors, strutils, winlean]

# Win32 API
proc createMutex(attributes: pointer, initialOwner: cint, name: WideCString): Handle
  {.importc: "CreateMutexW", dynlib: "kernel32", stdcall.}
  ## Creates or opens a named mutex; returns 0 on failure.

proc releaseMutex(mutex: Handle): cint
  {.importc: "ReleaseMutex", dynlib: "kernel32", stdcall.}
  ## Releases a mutex owned by the calling thread; returns 0 on failure.

const
  WAIT_ABANDONED = 0x00000080'i32
  LaunchMutexName = r"Local\TRNRun_LaunchMutex"
  LaunchLockTimeoutMs = 1_800_000'i32
    ## Deadlock backstop, not a queue policy: keep well above (queue depth - 1) x hold time.

var
  initLock: Lock
  launchMutexHandle: Handle = 0

initLock.initLock()

# Initialization
proc getLaunchMutex(): Handle =
  ## Returns the session-wide launch mutex, opening it once under `initLock`; `OSError` on failure.
  withLock initLock:
    if launchMutexHandle == 0:
      let
        mutexName = newWideCString(LaunchMutexName)
        handle = createMutex(nil, 0, mutexName)
      if handle == 0:
        raiseOSError(osLastError(), "Failed to create or open the TRNSYS launch mutex.")
      launchMutexHandle = handle
    result = launchMutexHandle

# Lock operations
proc acquireLaunchLock(): Handle =
  ## Blocks for the launch mutex, warning if abandoned; raises `IOError` on timeout, else `OSError`.
  let mutex = getLaunchMutex()
  case waitForSingleObject(mutex, LaunchLockTimeoutMs)
  of WAIT_OBJECT_0:
    discard
  of WAIT_ABANDONED:
    try:
      stderr.writeLine(
        "Warning: a previous TRNSYS process did not exit cleanly. Proceeding anyway.",
      )
    except IOError:
      discard # The mutex is already owned and must still be returned.
  of WAIT_TIMEOUT:
    raise newException(
      IOError,
      "Timed out after " & $(LaunchLockTimeoutMs div 1000) &
        " s waiting for the TRNSYS launch mutex. Another trnrun in this logon " &
        "session is holding it - look for a wedged TrnEXE64.exe.",
    )
  else:
    raiseOSError(osLastError(), "Failed to acquire the TRNSYS launch mutex.")

  return mutex

proc releaseLaunchLock(mutex: Handle) =
  ## Releases the launch mutex on the acquiring thread, reporting rather than raising on failure.
  if releaseMutex(mutex) == 0:
    # Never silent: a stuck mutex strands every launcher in the session.
    let errorCode = osLastError()
    try:
      stderr.writeLine(
        "Warning: failed to release the TRNSYS launch mutex (" &
          osErrorMsg(errorCode).strip() &
          "). Released from a different thread than acquired it?",
      )
    except IOError:
      discard # Do not mask an exception from the protected launch code.

# Public API
template withLaunchLock*(body: untyped) =
  ## Runs `body` holding the launch mutex, always releasing it; acquire errors raise before `body`.
  let mutex = acquireLaunchLock()
  try:
    body
  finally:
    releaseLaunchLock(mutex)
