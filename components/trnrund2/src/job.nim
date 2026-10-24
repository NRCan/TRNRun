## Places this process in a kill-on-close Windows Job Object.
##
## Every child and grandchild started afterwards joins the job too. Windows
## closes the job handle when this process exits, whether normally, through an
## unhandled exception, or by crashing, and the job then kills every TRNRun
## and TrnEXE still running.

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
  ## Creates a Job Object; returns 0 on failure.

proc setInformationJobObject(
    hJob: Handle,
    infoClass: int32,
    lpInfo: pointer,
    cbLen: uint32,
): int32 {.importc: "SetInformationJobObject", dynlib: "kernel32", stdcall.}
  ## Sets one class of Job Object limits; returns 0 on failure.

proc assignProcessToJobObject(hJob, hProcess: Handle): int32
  {.importc: "AssignProcessToJobObject", dynlib: "kernel32", stdcall.}
  ## Adds a process to a Job Object; returns 0 on failure.

var jobHandle: Handle = 0 ## This process's job; 0 until `initJobGuard` succeeds.

proc setKillOnClose(job: Handle) =
  ## Makes closing `job` kill every process in it; `OSError` on failure.
  let limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION(
    basicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION(
      limitFlags: JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    ),
  )
  let configured = setInformationJobObject(
    hJob = job,
    infoClass = JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS,
    lpInfo = addr limits,
    cbLen = uint32(sizeof(limits)),
  )
  if configured == 0:
    raiseOSError(osLastError(), "Failed to configure Job Object limits.")

# Public API

proc initJobGuard*() =
  ## Places this process in a new kill-on-close Job Object.
  ##
  ## Call it before starting any TRNRun: only processes started afterwards join
  ## the job. The job handle stays open until this process exits, and Windows
  ## then kills every process still in the job. Calling it again does nothing.
  ## Raises `OSError` if the job cannot be created, configured or joined, and
  ## leaves no handle open in that case.
  if jobHandle != 0:
    return

  var handle = createJobObjectW(nil, nil)
  if handle == 0:
    raiseOSError(osLastError(), "Failed to create Win32 Job Object.")

  try:
    setKillOnClose(handle)
    if assignProcessToJobObject(handle, getCurrentProcess()) == 0:
      raiseOSError(osLastError(), "Failed to place this process in the Job Object.")

    jobHandle = handle
    handle = 0 # Kept open until the process exits: closing it kills the job.
  finally:
    if handle != 0:
      discard closeHandle(handle)
