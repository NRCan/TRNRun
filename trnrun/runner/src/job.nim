## Windows Job Object lifetime guard for child TRNSYS processes.
##
## Ensures that any TRNSYS process spawned by this application is
## automatically killed by the OS when the parent exits, regardless of
## how the parent exits.
##
## Typical usage:
##
## ```nim
## let p = startProcess("TRNSYS.exe", …)
## assignToJob(p)
## ```

import std/[osproc, os, winlean]

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
  PROCESS_ALL_ACCESS = 0x1F0FFF'u32

proc createJobObjectW(lpJobAttributes, lpName: pointer): Handle
  {.importc: "CreateJobObjectW", dynlib: "kernel32", stdcall.}

proc setInformationJobObject( hJob: Handle, infoClass: int32, lpInfo: pointer, cbLen: uint32): int32
  {.importc: "SetInformationJobObject", dynlib: "kernel32", stdcall.}

proc assignProcessToJobObject(hJob, hProcess: Handle): int32
  {.importc: "AssignProcessToJobObject", dynlib: "kernel32", stdcall.}

proc openProcess(dwDesiredAccess: uint32, bInheritHandle: int32, dwProcessId: uint32): Handle
  {.importc: "OpenProcess", dynlib: "kernel32", stdcall.}

# ---------------------------------------------------------------------------
# Module-level Job Object
# ---------------------------------------------------------------------------
let jobHandle = createJobObjectW(nil, nil)
if jobHandle == 0:
  raiseOSError(osLastError(), "Failed to create Win32 Job Object.")

var info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

if setInformationJobObject(jobHandle, JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS, addr info, sizeof(info).uint32) == 0:
  raiseOSError(osLastError(), "Failed to configure Job Object limits.")

# ---------------------------------------------------------------------------
# Public Interface
# ---------------------------------------------------------------------------
proc assignToJob*(process: Process) =
  ## Binds `process` to the global job object. The OS kills it if we exit.
  let handle = openProcess(PROCESS_ALL_ACCESS, 0, process.processId().uint32)
  if handle == 0:
    return  # process already gone
  defer: discard closeHandle(handle)
  discard assignProcessToJobObject(jobHandle, handle)
