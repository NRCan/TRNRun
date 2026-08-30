import std/unittest

include ../src/job


proc isProcessInJob(
    processHandle: Handle,
    job: Handle,
    result: ptr int32,
): int32 {.importc: "IsProcessInJob", dynlib: "kernel32", stdcall.}

proc queryInformationJobObject(
    job: Handle,
    infoClass: int32,
    info: pointer,
    length: uint32,
    returnLength: ptr uint32,
): int32 {.importc: "QueryInformationJobObject", dynlib: "kernel32", stdcall.}


suite "Windows Job Object guard":
  test "configures and joins one kill-on-close job":
    check jobHandle == 0

    initJobGuard()
    let initialHandle = jobHandle

    check initialHandle != 0

    var processIsInJob = 0'i32
    check isProcessInJob(
      getCurrentProcess(),
      initialHandle,
      addr processIsInJob,
    ) != 0
    check processIsInJob != 0

    var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    check queryInformationJobObject(
      initialHandle,
      JOB_OBJECT_EXTENDED_LIMIT_INFO_CLASS,
      addr limits,
      uint32(sizeof(limits)),
      nil,
    ) != 0
    check limits.basicLimitInformation.limitFlags ==
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE

    initJobGuard()
    check jobHandle == initialHandle
