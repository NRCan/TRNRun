## job.nim - Windows Job Object lifetime guard for child TRNSYS processes.
##
## Ensures that any TRNSYS process spawned by this application is
## automatically killed by the OS when the parent exits, regardless of how
## the parent exits (normal return, unhandled exception, or crash).
##
## The guard works by placing this process into a kill-on-close job
## object. Job membership is inherited across `CreateProcess`, so children,
## grandchildren, and anything TRNSYS starts internally are all covered.
##
## Typical usage:
##
## ```nim
## initJobGuard()                          # once, at startup, before workers
## let p = startProcess("trnrun.exe", …)   # captured automatically
## ```

when not defined(windows):
  {.error: "job.nim is Windows-only. Guard the import with `when defined(windows)`.".}

import std/[winlean, oserrors]

# ---------------------------------------------------------------------------
# Win32 API
# ---------------------------------------------------------------------------
type
  JOBOBJECT_BASIC_LIMIT_INFORMATION = object
    PerProcessUserTimeLimit: int64
    PerJobUserTimeLimit: int64
    LimitFlags: uint32
    MinimumWorkingSetSize: uint
    MaximumWorkingSetSize: uint
    ActiveProcessLimit: uint32
    Affinity: uint
    PriorityClass: uint32
    SchedulingClass: uint32

  IO_COUNTERS = object
    ReadOperationCount: uint64
    WriteOperationCount: uint64
    OtherOperationCount: uint64
    ReadTransferCount: uint64
    WriteTransferCount: uint64
    OtherTransferCount: uint64

  JOBOBJECT_EXTENDED_LIMIT_INFORMATION = object
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION
    IoInfo: IO_COUNTERS
    ProcessMemoryLimit: uint
    JobMemoryLimit: uint
    PeakProcessMemoryUsed: uint
    PeakJobMemoryUsed: uint

const
  JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS = 9'i32
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000'u32

proc createJobObjectW(
  lpJobAttributes, lpName: pointer
): Handle {.importc: "CreateJobObjectW", dynlib: "kernel32", stdcall.}

proc setInformationJobObject(
  hJob: Handle, infoClass: int32, lpInfo: pointer, cbLen: uint32
): int32 {.importc: "SetInformationJobObject", dynlib: "kernel32", stdcall.}

proc assignProcessToJobObject(
  hJob, hProcess: Handle
): int32 {.importc: "AssignProcessToJobObject", dynlib: "kernel32", stdcall.}

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------
var jobHandle: Handle = 0

# ---------------------------------------------------------------------------
# Public interface
# ---------------------------------------------------------------------------
proc initJobGuard*() =
  ## Creates the kill-on-close job object and places this process in it.
  ##
  ## Call once from the main thread during startup, before spawning any child
  ## and before starting any worker threads. Job membership belongs to the
  ## process, not the calling thread, so a single call covers every deck any
  ## worker later spawns. Repeat calls are a no-op, which keeps a caller that
  ## runs several decks in sequence from leaking a job per run.
  ##
  ## Returns
  ## -------
  ## None
  if jobHandle != 0:
    return

  let h = createJobObjectW(nil, nil)
  if h == 0:
    raiseOSError(osLastError(), "Failed to create Win32 Job Object.")

  var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
  info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
  if setInformationJobObject(
    h, JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS, addr info, sizeof(info).uint32
  ) == 0:
    let err = osLastError()
    discard closeHandle(h)
    raiseOSError(err, "Failed to configure Job Object limits.")

  if assignProcessToJobObject(h, getCurrentProcess()) == 0:
    let err = osLastError()
    discard closeHandle(h)
    raiseOSError(err, "Failed to place this process in the Job Object.")

  jobHandle = h

proc jobGuardActive*(): bool =
  ## Whether the guard is in force.
  ##
  ## Returns
  ## -------
  ## bool
  ##     True once `initJobGuard` has completed successfully.
  jobHandle != 0
