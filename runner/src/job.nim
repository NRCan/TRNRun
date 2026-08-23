## Keeps this process and inherited descendants in a kill-on-close Windows Job
## Object.
##
## Once this process joins the job, child and grandchild membership is
## inherited. TrnEXE descendants are terminated when the parent process exits
## and closes the job handle, whether normally, through an unhandled exception,
## or by crashing.
##
## Typical usage:
##
## ```nim
## initJobGuard()                          # once, at startup, before workers
## let p = startProcess("trnrun.exe", …)   # captured automatically
## ```

when not defined(windows):
  {.error: "job.nim is Windows-only. Guard the import with `when defined(windows)`.".}

import std/[oserrors, winlean]

# Win32 API
type
  JOBOBJECT_BASIC_LIMIT_INFORMATION = object
    perProcessUserTimeLimit: int64
    perJobUserTimeLimit: int64
    limitFlags: uint32
    minimumWorkingSetSize: uint
    maximumWorkingSetSize: uint
    activeProcessLimit: uint32
    affinity: uint
    priorityClass: uint32
    schedulingClass: uint32

  IO_COUNTERS = object
    readOperationCount: uint64
    writeOperationCount: uint64
    otherOperationCount: uint64
    readTransferCount: uint64
    writeTransferCount: uint64
    otherTransferCount: uint64

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION = object
    basicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION
    ioInfo: IO_COUNTERS
    processMemoryLimit: uint
    jobMemoryLimit: uint
    peakProcessMemoryUsed: uint
    peakJobMemoryUsed: uint

const
  JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS = 9'i32
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000'u32

proc createJobObjectW(lpJobAttributes, lpName: pointer): Handle
  {.importc: "CreateJobObjectW", dynlib: "kernel32", stdcall.}

proc setInformationJobObject(
    hJob: Handle,
    infoClass: int32,
    lpInfo: pointer,
    cbLen: uint32,
): int32 {.importc: "SetInformationJobObject", dynlib: "kernel32", stdcall.}

proc assignProcessToJobObject(hJob, hProcess: Handle): int32
  {.importc: "AssignProcessToJobObject", dynlib: "kernel32", stdcall.}

# Module state
var jobHandle: Handle = 0

# Public API
proc initJobGuard*() =
  ## Creates the kill-on-close job object and places this process in it.
  ##
  ## Call once from the main thread during startup, before spawning any child
  ## and before starting any worker threads. Job membership belongs to the
  ## process, not the calling thread, so a single call covers every deck any
  ## worker later spawns. Repeat calls are a no-op, which keeps a caller that
  ## runs several decks in sequence from leaking a job per run.
  if jobHandle != 0:
    return

  var handle = createJobObjectW(nil, nil)
  if handle == 0:
    raiseOSError(osLastError(), "Failed to create Win32 Job Object.")

  defer:
    if handle != 0:
      discard closeHandle(handle)

  var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
  limits.basicLimitInformation.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
  if setInformationJobObject(
    handle,
    JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS,
    addr limits,
    uint32(sizeof(limits)),
  ) == 0:
    raiseOSError(osLastError(), "Failed to configure Job Object limits.")

  if assignProcessToJobObject(handle, getCurrentProcess()) == 0:
    raiseOSError(osLastError(), "Failed to place this process in the Job Object.")

  jobHandle = handle
  handle = 0 # Ownership remains with the module until process exit.
