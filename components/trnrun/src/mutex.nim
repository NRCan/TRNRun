## Serializes TrnEXE launches across the whole machine.
##
## TRNSYS does not tolerate simultaneous launches, so every runner uses the
## named `Global\TRNRun_LaunchMutex`. It is shared by all sessions (console,
## RDP, SSH) and all users: its DACL lets any authenticated user wait on and
## release it. Win32 mutex ownership is per thread: release must occur on the
## acquiring thread, and nested acquisition is safe.
##
## ```nim
## withLaunchLock:
##   startProcess("TrnEXE64.exe", …)
## ```

when not defined(windows):
  {.error: "mutex.nim is Windows-only.".}

import std/[locks, oserrors, strutils, winlean]

# Win32 API
proc createMutexEx(
  attributes: ptr SECURITY_ATTRIBUTES, name: WideCString, flags: int32,
  desiredAccess: int32,
): Handle {.importc: "CreateMutexExW", dynlib: "kernel32", stdcall.}
  ## Creates or opens a named mutex with only `desiredAccess`; returns 0 on failure.
  ## Unlike `CreateMutexW`, opening an existing mutex does not demand
  ## `MUTEX_ALL_ACCESS`, which the shared DACL does not grant.

proc convertStringSecurityDescriptorToSecurityDescriptor(
  sddl: WideCString, revision: int32, descriptor: var pointer, size: pointer,
): WINBOOL {.importc: "ConvertStringSecurityDescriptorToSecurityDescriptorW",
  dynlib: "advapi32", stdcall.}
  ## Parses an SDDL string into a descriptor freed with `LocalFree`; returns 0 on failure.

proc releaseMutex(mutex: Handle): cint
  {.importc: "ReleaseMutex", dynlib: "kernel32", stdcall.}
  ## Releases a mutex owned by the calling thread; returns 0 on failure.

const
  WAIT_ABANDONED = 0x00000080'i32
  MUTEX_MODIFY_STATE = 0x00000001'i32
  SDDL_REVISION_1 = 1'i32
  LaunchMutexName = r"Global\TRNRun_LaunchMutex"
  LaunchMutexAccess = SYNCHRONIZE or MUTEX_MODIFY_STATE
    ## Exactly what waiting and releasing need.
  LaunchMutexSddl = "D:(A;;0x100001;;;AU)"
    ## Authenticated Users get `LaunchMutexAccess`, so users other than the
    ## creator can share the mutex instead of failing with access denied.
  LaunchLockTimeoutMs = 1_800_000'i32
    ## Deadlock backstop, not a queue policy: keep well above (queue depth - 1) x hold time.

var
  initLock: Lock
  launchMutexHandle: Handle = 0

initLock.initLock()

# Initialization
proc getLaunchMutex(): Handle =
  ## Returns the machine-wide launch mutex, opening it once under `initLock`; `OSError` on failure.
  withLock initLock:
    if launchMutexHandle == 0:
      var descriptor: pointer = nil
      if convertStringSecurityDescriptorToSecurityDescriptor(
        newWideCString(LaunchMutexSddl), SDDL_REVISION_1, descriptor, nil,
      ) == 0:
        raiseOSError(osLastError(), "Failed to build the TRNSYS launch mutex DACL.")
      try:
        var attributes = SECURITY_ATTRIBUTES(
          nLength: sizeof(SECURITY_ATTRIBUTES).int32,
          lpSecurityDescriptor: descriptor,
          bInheritHandle: 0,
        )
        # The DACL applies only when this call creates the mutex; opening ignores it.
        let handle = createMutexEx(
          addr attributes, newWideCString(LaunchMutexName), 0, LaunchMutexAccess,
        )
        if handle == 0:
          let errorCode = osLastError()
          if errorCode.int32 == ERROR_ACCESS_DENIED:
            # Someone else created the name without the shared DACL.
            raiseOSError(
              errorCode,
              "The TRNSYS launch mutex already exists but denies access to this " &
                "user. Another user's process (an older trnrun or another tool) " &
                "created it with incompatible permissions - close that process and retry.",
            )
          raiseOSError(errorCode, "Failed to create or open the TRNSYS launch mutex.")
        launchMutexHandle = handle
      finally:
        localFree(descriptor)
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
        " s waiting for the TRNSYS launch mutex. Another trnrun on this machine " &
        "is holding it - look for a wedged TrnEXE64.exe.",
    )
  else:
    raiseOSError(osLastError(), "Failed to acquire the TRNSYS launch mutex.")

  return mutex

proc releaseLaunchLock(mutex: Handle) =
  ## Releases the launch mutex on the acquiring thread, reporting rather than raising on failure.
  if releaseMutex(mutex) == 0:
    # Never silent: a stuck mutex strands every launcher on the machine.
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
