## Serializes TrnEXE launches across processes and threads in one Windows logon
## session.
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
proc createMutex(attributes: pointer; initialOwner: cint; name: WideCString): Handle
  {.importc: "CreateMutexW", dynlib: "kernel32", stdcall.}

proc releaseMutex(mutex: Handle): cint
  {.importc: "ReleaseMutex", dynlib: "kernel32", stdcall.}

const
  WAIT_ABANDONED = 0x00000080'i32
  LaunchMutexName = r"Local\TRNRun_LaunchMutex"
  LaunchLockTimeoutMs = 1_800_000'i32
    ## Deadlock backstop, not a queueing policy. Every runner in the session
    ## queues here, so a legitimate wait is (queue depth - 1) x hold time and
    ## the manager sizes its pool at cpu_count - 1. This must stay well above
    ## that product; `detectTimeoutMs` is what bounds the hold time itself.

var
  initLock: Lock
  launchMutexHandle: Handle = 0

initLock.initLock()

# Initialization
proc getLaunchMutex(): Handle =
  ## Returns the session-wide launch mutex, creating or opening it on the
  ## first call. All access to `launchMutexHandle` goes through here, so the
  ## handle is never read outside `initLock`.
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
  ## Blocks until the TRNSYS launch mutex is acquired.
  ##
  ## `WAIT_ABANDONED` transfers ownership after a previous holder dies; the
  ## launch continues with a warning. Raises `OSError` if the mutex cannot be
  ## created, opened, or acquired, and `IOError` if the wait times out.
  let mutex = getLaunchMutex()
  case waitForSingleObject(mutex, LaunchLockTimeoutMs)
  of WAIT_OBJECT_0:
    discard
  of WAIT_ABANDONED:
    try:
      stderr.writeLine("Warning: a previous TRNSYS process did not exit cleanly. Proceeding anyway.")
    except IOError:
      discard # The mutex is already owned and must still be returned.
  of WAIT_TIMEOUT:
    raise newException(
      IOError,
      "Timed out after " & $(LaunchLockTimeoutMs div 1000) &
        " s waiting for the TRNSYS launch mutex. Another trnrun in this logon " &
        "session is holding it - look for a wedged TrnEXE64.exe."
    )
  else:
    raiseOSError(osLastError(), "Failed to acquire the TRNSYS launch mutex.")

  return mutex

proc releaseLaunchLock(mutex: Handle) =
  ## Releases the TRNSYS launch mutex.
  ##
  ## Must be called from the thread that acquired it - Win32 mutex
  ## ownership is thread-scoped. A failed release is reported rather than
  ## discarded, because it strands every launcher in the session.
  if releaseMutex(mutex) == 0:
    let errorCode = osLastError()
    try:
      stderr.writeLine(
        "Warning: failed to release the TRNSYS launch mutex (" &
          osErrorMsg(errorCode).strip() &
          "). Released from a different thread than acquired it?"
      )
    except IOError:
      discard # Do not mask an exception from the protected launch code.

# Public API
template withLaunchLock*(body: untyped) =
  ## Runs `body` while holding the TRNSYS launch mutex.
  ##
  ## Always releases the mutex afterward, including when `body` raises.
  ## Raises `OSError` if the mutex cannot be created, opened, or acquired, and
  ## `IOError` if another runner holds it past `LaunchLockTimeoutMs`. Both are
  ## raised before the lock is taken, so `body` never runs unlocked.
  let mutex = acquireLaunchLock()
  try:
    body
  finally:
    releaseLaunchLock(mutex)
