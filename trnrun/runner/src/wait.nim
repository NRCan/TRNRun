## Startup detection for TRNSYS processes.
##
## The single public entry point is `waitReady`, which runs up to three
## detection stages in sequence — each bounded by the same shared timeout:
##
## 1. **GUI** – waits for a top-level window of a known TRNSYS class to appear.
## 2. **LST** – waits for the simulation `.lst` file to contain the
##    component-order header, indicating the deck was parsed successfully.
## 3. **TMP** – waits for the `.tmp` lock file to appear, indicating
##    TRNSYS has opened its output files and is ready to be monitored.
##
## Returns `wrReady`, `wrTimeout`, or `wrDied`.

import std/[os, osproc, times, monotimes, strutils, sets, winlean]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
type
  LPARAM = int
  EnumWindowsProc = proc(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.}
  CallbackData = object
    pid: int32
    foundHwnd: Handle
    guiClasses: HashSet[string]

  WaitResult* = enum
    wrReady # All detection conditions passed.
    wrTimeout # Process still running but did not meet conditions in time.
    wrDied # Process crashed or exited prematurely.

# ---------------------------------------------------------------------------
# Win32 API
# ---------------------------------------------------------------------------
proc enumWindows(lpEnumFunc: EnumWindowsProc, lParam: LPARAM): int32
  {.importc: "EnumWindows", dynlib: "user32", stdcall.}

proc getClassNameW(hWnd: Handle, lpClassName: WideCString, nMaxCount: int32): int32
  {.importc: "GetClassNameW", dynlib: "user32", stdcall.}

proc getWindowThreadProcessId(hWnd: Handle, lpdwProcessId: ptr int32): int32
  {.importc: "GetWindowThreadProcessId", dynlib: "user32", stdcall.}

# ---------------------------------------------------------------------------
# Poll
# ---------------------------------------------------------------------------
proc poll(
    condition: proc(): bool,
    timeoutMs: int = 0,
    initialIntervalMs: int = 10,
    maxIntervalMs: int = 500,
    backoff: float = 1.3,
): bool =
  ## Polls `condition` with exponential backoff until it returns true or the timeout expires.
  if initialIntervalMs <= 0:
    raise newException(ValueError, "initialIntervalMs must be positive")
  if maxIntervalMs < initialIntervalMs:
    raise newException(ValueError, "maxIntervalMs must be >= initialIntervalMs")
  if backoff <= 1.0:
    raise newException(ValueError, "backoff must be > 1.0")
  if timeoutMs < 0:
    raise newException(ValueError, "timeoutMs must be >= 0")

  let infinite = timeoutMs == 0

  let deadline =
    if infinite:
      MonoTime()  # unused placeholder
    else:
      getMonoTime() + initDuration(milliseconds = timeoutMs)

  var delay = initialIntervalMs.float

  while true:
    if condition():
      return true

    if not infinite:
      let now = getMonoTime()
      if now >= deadline:
        return false

      let remaining = (deadline - now).inMilliseconds.int
      if remaining <= 0:
        return false

      sleep(min(delay.int, remaining))
    else:
      sleep(delay.int)

    delay = min(delay * backoff, maxIntervalMs.float)

# ---------------------------------------------------------------------------
# File-based waiters
# ---------------------------------------------------------------------------
const LstHeader = "*** The TRNSYS components will be called in the following order:"

proc checkLst(lstFile: string): bool =
  ## Returns true if the .lst file contains the TRNSYS component-order header.
  try: LstHeader in readFile(lstFile)
  except IOError: false

proc waitLst(process: Process, deckFile: string, timeoutMs: int): bool =
  ## Waits for the .lst file to contain the header. Returns true only if found.
  let lstFile = changeFileExt(deckFile, "lst")
  var found = false

  let cond = proc(): bool =
    if checkLst(lstFile):
      found = true
      return true
    if not process.running:
      return true # Stop polling immediately
    return false

  discard poll(cond, timeoutMs)
  return found

proc waitTmp(process: Process, deckFile: string, timeoutMs: int): bool =
  ## Waits for the .tmp file to appear. Returns true only if found.
  let tmpFile = changeFileExt(deckFile, "tmp")
  var found = false

  let cond = proc(): bool =
    if fileExists(tmpFile):
      found = true
      return true
    if not process.running:
      return true # Stop polling immediately
    return false

  discard poll(cond, timeoutMs)
  return found

# ---------------------------------------------------------------------------
# GUI waiter
# ---------------------------------------------------------------------------
proc enumCallback(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.} =
  ## EnumWindows callback: records the first window matching the target pid and class.
  let data = cast[ptr CallbackData](lParam)
  var winPid: int32 = 0
  discard getWindowThreadProcessId(hwnd, addr winPid)

  if winPid != data.pid: return 1

  var buf: array[256, Utf16Char]
  let ws = cast[WideCString](addr buf[0])
  if getClassNameW(hwnd, ws, 256) > 0 and $ws in data.guiClasses:
    data.foundHwnd = hwnd
    return 0
  return 1

proc waitGui(
    process: Process,
    guiClasses: openArray[string] = ["TProg32", "TOnlineWindow"],
    timeoutMs: int = 120_000,
): bool =
  ## Returns true when a top-level window with one of the given class names appears for the process.
  var data = CallbackData(
    pid: int32(process.processId()),
    foundHwnd: 0,
    guiClasses: guiClasses.toHashSet,
  )

  let cond = proc(): bool =
    if not process.running:
      return true

    data.foundHwnd = 0
    discard enumWindows(enumCallback, cast[LPARAM](addr data))
    return data.foundHwnd != 0

  discard poll(cond, timeoutMs)
  return data.foundHwnd != 0


# ---------------------------------------------------------------------------
# waitReady
# ---------------------------------------------------------------------------
proc waitReady*(
    process: Process,
    deckFile: string,
    waitForGui: bool,
    waitForLst: bool,
    waitForTmp: bool,
    timeoutMs: int,
    extraDelayMs: int,
): WaitResult =
  ## Runs each enabled detection stage in order; returns wrReady, wrTimeout, or wrDied.
  if not process.running:
    return wrDied

  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)

  template remainingMs(): int =
    max(0, (deadline - getMonoTime()).inMilliseconds.int)

  if waitForGui:
    if not waitGui(process, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrDied

  if waitForLst:
    if not waitLst(process, deckFile, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrDied

  if waitForTmp:
    if not waitTmp(process, deckFile, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrDied

  if extraDelayMs > 0:
    let diedDuringDelay = poll(condition = proc(): bool = not process.running, timeoutMs = extraDelayMs)
    if diedDuringDelay or not process.running:
      return wrDied

  return if process.running: wrReady else: wrDied
