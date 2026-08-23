## wait.nim - startup detection for TRNSYS processes.
##
## The single public entry point is `waitReady`, which runs up to three
## detection stages in sequence - each bounded by the same shared timeout:
##
## 1. **GUI** – waits for a top-level window of a known TRNSYS class to appear.
## 2. **LST** – waits for the simulation `.lst` file to contain the
##    component-order header, indicating the deck was parsed successfully.
## 3. **TMP** – waits for the `.tmp` lock file to appear, indicating
##    TRNSYS has opened its output files and is ready to be monitored.
##
## Returns `wrReady`, `wrTimeout`, or `wrDied`.
##
## Also exposes `minimizeGui`, which drives TRNSYS windows into the minimized
## state, since TrnEXE has no command-line switch for it.

import std/[os, osproc, times, monotimes, strutils, sets, winlean]
import ./processwait

# Types
type
  LPARAM = int
  EnumWindowsProc = proc(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.}

  CallbackData = object
    ## State passed to `enumCallback` while searching for one window.
    pid: int32
    foundHwnd: Handle
    guiClasses: HashSet[string]

  CollectData = object
    ## State passed to `collectCallback` while collecting all windows.
    pid: int32
    guiClasses: HashSet[string]
    found: seq[Handle]

  WaitResult* = enum
    ## Outcome of the readiness-detection phase.
    wrReady # All detection conditions passed.
    wrTimeout # Process still running but did not meet conditions in time.
    wrDied # Process crashed or exited prematurely.

const DefaultGuiClasses* = ["TProg32", "TOnlineWindow"]
  ## Window class names recognised as TRNSYS top-level windows.

# Win32 API
proc enumWindows(lpEnumFunc: EnumWindowsProc, lParam: LPARAM): int32
  {.importc: "EnumWindows", dynlib: "user32", stdcall.}

proc getClassNameW(hWnd: Handle, lpClassName: WideCString, nMaxCount: int32): int32
  {.importc: "GetClassNameW", dynlib: "user32", stdcall.}

proc getWindowThreadProcessId(hWnd: Handle, lpdwProcessId: ptr int32): int32
  {.importc: "GetWindowThreadProcessId", dynlib: "user32", stdcall.}

proc showWindow(hWnd: Handle, nCmdShow: int32): int32
  {.importc: "ShowWindow", dynlib: "user32", stdcall.}

proc isIconic(hWnd: Handle): int32
  {.importc: "IsIconic", dynlib: "user32", stdcall.}

proc isWindowVisible(hWnd: Handle): int32
  {.importc: "IsWindowVisible", dynlib: "user32", stdcall.}

proc getWindowTextLengthW(hWnd: Handle): int32
  {.importc: "GetWindowTextLengthW", dynlib: "user32", stdcall.}

const SW_SHOWMINNOACTIVE = 7'i32

# Polling
type PollCondition = proc(): bool {.closure, gcsafe.}

proc poll(
    process: Process,
    condition: PollCondition,
    timeoutMs: int = 0,
    initialIntervalMs: int = 10,
    maxIntervalMs: int = 500,
    backoff: float = 1.3,
): bool {.gcsafe.} =
  ## Polls `condition` with exponential backoff until it returns true or
  ## `timeoutMs` (0 = forever) expires.
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
      MonoTime() # unused placeholder
    else:
      getMonoTime() + initDuration(milliseconds = timeoutMs)

  var delay = initialIntervalMs.float
  result = false

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

      if process.waitForExitNonDestructive(min(delay.int, remaining)):
        return condition() # Last-chance read of files flushed just before exit.
    else:
      if process.waitForExitNonDestructive(delay.int):
        return condition()

    delay = min(delay * backoff, maxIntervalMs.float)

# File-based readiness
const LstHeader =
  "*** The TRNSYS components will be called in the following order:"

proc checkLst(lstFile: string): bool =
  ## Returns true if the .lst file contains the TRNSYS component-order header.
  try:
    LstHeader in readFile(lstFile)
  except IOError:
    false

proc waitLst(process: Process, deckFile: string, timeoutMs: int): bool =
  ## Waits for the `.lst` header to appear; returns true only if found (stops
  ## early if the process exits).
  let lstFile = changeFileExt(deckFile, "lst")
  var found = false

  let cond = proc(): bool =
    if checkLst(lstFile):
      found = true
      return true
    if not process.running:
      return true # Stop polling immediately
    return false

  discard poll(process, cond, timeoutMs)
  return found

proc waitTmp(process: Process, deckFile: string, timeoutMs: int): bool =
  ## Waits for the `.tmp` file to appear; returns true only if found (stops
  ## early if the process exits).
  let tmpFile = changeFileExt(deckFile, "tmp")
  var found = false

  let cond = proc(): bool =
    if fileExists(tmpFile):
      found = true
      return true
    if not process.running:
      return true # Stop polling immediately
    return false

  discard poll(process, cond, timeoutMs)
  return found

# GUI readiness
proc enumCallback(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.} =
  ## EnumWindows callback: records the first window matching the target pid and
  ## class.
  let data = cast[ptr CallbackData](lParam)
  var winPid: int32 = 0
  discard getWindowThreadProcessId(hwnd, addr winPid)

  if winPid != data.pid: return 1

  # if isWindowVisible(hwnd) == 0: return 1
  # if getWindowTextLengthW(hwnd) == 0: return 1

  var buf = default(array[256, Utf16Char])
  let ws = cast[WideCString](addr buf[0])
  if getClassNameW(hwnd, ws, 256) > 0 and $ws in data.guiClasses:
    data.foundHwnd = hwnd
    return 0
  return 1

proc waitGui(
    process: Process,
    guiClasses: openArray[string] = DefaultGuiClasses,
    timeoutMs: int = 120_000,
): bool =
  ## Returns true when a top-level window of one of `guiClasses` appears for the
  ## process.
  var data = CallbackData(
    pid: int32(process.processID()),
    foundHwnd: 0,
    guiClasses: guiClasses.toHashSet,
  )

  let cond = proc(): bool =
    if not process.running:
      return true

    data.foundHwnd = 0
    discard enumWindows(enumCallback, cast[LPARAM](addr data))
    return data.foundHwnd != 0

  discard poll(process, cond, timeoutMs)
  return data.foundHwnd != 0

# GUI minimization
proc collectCallback(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.} =
  ## EnumWindows callback: collects *every* window matching the target pid and
  ## class.
  let data = cast[ptr CollectData](lParam)
  var winPid: int32 = 0
  discard getWindowThreadProcessId(hwnd, addr winPid)

  if winPid != data.pid: return 1

  if isWindowVisible(hwnd) == 0: return 1
  if getWindowTextLengthW(hwnd) == 0: return 1

  var buf = default(array[256, Utf16Char])
  let ws = cast[WideCString](addr buf[0])
  if getClassNameW(hwnd, ws, 256) > 0 and $ws in data.guiClasses:
    data.found.add(hwnd)
  return 1

proc windowsOf(process: Process, guiClasses: openArray[string]): seq[Handle] =
  ## Returns all top-level windows of `process` whose class is in `guiClasses`.
  var data = CollectData(
    pid: int32(process.processID()),
    guiClasses: guiClasses.toHashSet,
    found: @[],
  )
  discard enumWindows(collectCallback, cast[LPARAM](addr data))
  return data.found

proc minimizeGui*(
    process: Process,
    guiClasses: openArray[string] = DefaultGuiClasses,
    timeoutMs: int = 10_000,
): bool {.discardable.} =
  ## Waits for a matching window, then minimizes all matching windows without
  ## stealing focus; one-shot, idempotent, false if none appeared in time.
  let classes = @guiClasses # openArray can't be captured by the closure below.
  var done = false

  let cond = proc(): bool =
    if not process.running:
      return true
    for hwnd in windowsOf(process, classes):
      if isIconic(hwnd) == 0:
        discard showWindow(hwnd, SW_SHOWMINNOACTIVE)
        done = true
    return done

  discard poll(process, cond, timeoutMs)
  return done

# Readiness orchestration
proc waitReady*(
    process: Process,
    deckFile: string,
    waitForGui: bool,
    waitForLst: bool,
    waitForTmp: bool,
    timeoutMs: int,
    extraDelayMs: int,
): WaitResult =
  ## Waits for a freshly launched TRNSYS process to become ready.
  ##
  ## Runs up to three detection stages in order - GUI window, `.lst`
  ## header, `.tmp` file - each bounded by the same shared deadline,
  ## followed by an optional fixed delay.
  ##
  ## Parameters
  ## ----------
  ## process : Process
  ##     The freshly launched TRNSYS process to observe.
  ## deckFile : string
  ##     Deck path used to derive the `.lst` and `.tmp` file locations.
  ## waitForGui : bool
  ##     Wait for a top-level window of a known TRNSYS class to appear.
  ## waitForLst : bool
  ##     Wait for the `.lst` file to contain the component-order header.
  ## waitForTmp : bool
  ##     Wait for the `.tmp` file to appear.
  ## timeoutMs : int
  ##     Shared deadline across all enabled stages; <= 0 waits indefinitely.
  ## extraDelayMs : int
  ##     Additional delay after all stages pass; aborts early if the
  ##     process dies during the delay.
  ##
  ## Returns
  ## -------
  ## WaitResult
  ##     `wrReady` if all enabled stages passed, `wrTimeout` if the
  ##     deadline expired with the process still running, or `wrDied` if
  ##     the process exited at any point.
  if not process.running:
    return wrDied

  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)

  template remainingMs(): int =
    (if timeoutMs <= 0: 0
     else: max(1, (deadline - getMonoTime()).inMilliseconds.int))

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
    let diedDuringDelay = poll(
      process = process,
      condition = proc(): bool = not process.running,
      timeoutMs = extraDelayMs,
    )
    if diedDuringDelay or not process.running:
      return wrDied

  return if process.running: wrReady else: wrDied
