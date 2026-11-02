## Keeps Windows from idle-sleeping while a simulation runs.
##
## TRNSYS slows to a crawl when the PC sleeps mid-run. The request is per
## thread and Windows drops it when the thread exits. It does not block
## user-initiated sleep (closing the lid, Start > Sleep). It also keeps the
## screen on: Modern Standby laptops enter standby when the screen turns off.

when not defined(windows):
  {.error: "sleep.nim is Windows-only.".}

proc setThreadExecutionState(flags: uint32): uint32
  {.importc: "SetThreadExecutionState", dynlib: "kernel32", stdcall.}
  ## Returns the previous state, or 0 on failure.

const
  ES_SYSTEM_REQUIRED = 0x00000001'u32
  ES_DISPLAY_REQUIRED = 0x00000002'u32
  ES_CONTINUOUS = 0x80000000'u32

# Best effort both ways: a refusal only costs speed, never the run.
proc preventSleep*() =
  ## Blocks idle sleep and screen-off until `allowSleep` or this thread exits.
  discard setThreadExecutionState(ES_CONTINUOUS or ES_SYSTEM_REQUIRED or ES_DISPLAY_REQUIRED)

proc allowSleep*() =
  ## Clears this thread's `preventSleep` request.
  discard setThreadExecutionState(ES_CONTINUOUS)
