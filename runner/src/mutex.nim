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

import std/[os, locks, strutils, winlean]

# Win32 API
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
  LaunchMutexName = r"Local\TRNRun_LaunchMutex"

var
  initLock: Lock
  launchMutex: Handle = 0

initLock.initLock()

# Initialization
proc getLaunchMutex(): Handle =
  ## Returns the session-wide launch mutex, creating or opening it on the
  ## first call. All access to `launchMutex` goes through here, so the
  ## handle is never read outside `initLock`.
  withLock initLock:
    if launchMutex == 0:
      let handle = createMutex(nil, 0, newWideCString(LaunchMutexName))
      if handle == 0:
        raiseOSError(
          osLastError(), "Failed to create or open the TRNSYS launch mutex."
        )
      launchMutex = handle
    result = launchMutex

# Lock operations
proc acquireLaunchLock() =
  ## Blocks until the TRNSYS launch mutex is acquired.
  ##
  ## `WAIT_ABANDONED` transfers ownership after a previous holder dies; the
  ## launch continues with a warning. Raises `OSError` if the mutex cannot be
  ## created, opened, or acquired.
  let waitResult = waitForSingleObject(getLaunchMutex(), INFINITE)
  if waitResult == WAIT_ABANDONED:
    stderr.writeLine(
      "Warning: a previous TRNSYS process did not exit cleanly. " &
        "Proceeding anyway."
    )
  elif waitResult != WAIT_OBJECT_0:
    raiseOSError(osLastError(), "Failed to acquire the TRNSYS launch mutex.")

proc releaseLaunchLock() =
  ## Releases the TRNSYS launch mutex.
  ##
  ## Must be called from the thread that acquired it - Win32 mutex
  ## ownership is thread-scoped. A failed release is reported rather than
  ## discarded, because it strands every launcher in the session.
  if releaseMutex(getLaunchMutex()) == 0:
    let err = osLastError()
    stderr.writeLine(
      "Warning: failed to release the TRNSYS launch mutex (" &
        osErrorMsg(err).strip() &
        "). Released from a different thread than acquired it?"
    )

# Public API
template withLaunchLock*(body: untyped) =
  ## Runs `body` while holding the TRNSYS launch mutex.
  ##
  ## Always releases the mutex afterward, including when `body` raises.
  ## Raises `OSError` if the mutex cannot be created, opened, or acquired.
  acquireLaunchLock()
  try:
    body
  finally:
    releaseLaunchLock()
