## Coordinates TRNSYS startup detection and GUI minimization.
##
## `waitReady` checks enabled GUI, `.lst`, and `.tmp` readiness signals in that
## order against one shared timeout. `minimizeGui` provides the minimized modes
## that TrnEXE cannot select through its command line.

when not defined(windows):
  {.error: "wait.nim is Windows-only.".}

import std/[monotimes, os, osproc, sets, strutils, times, winlean]
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
    wrExited # Process exited during detection; see `waitReady`.

const
  DefaultGuiClasses = ["TProg32", "TOnlineWindow"]
    ## Window class names recognised as TRNSYS top-level windows.
  WindowClassBufferChars = 256

# Win32 API
proc enumWindows(lpEnumFunc: EnumWindowsProc, lParam: LPARAM): int32
  {.importc: "EnumWindows", dynlib: "user32", stdcall.}

proc getClassNameW(
    hWnd: Handle,
    lpClassName: WideCString,
    nMaxCount: int32,
): int32 {.importc: "GetClassNameW", dynlib: "user32", stdcall.}

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
    timeoutMs: int,
    initialIntervalMs: int = 10,
    maxIntervalMs: int = 500,
    backoff: float = 1.3,
): bool {.gcsafe.} =
  ## Polls `condition` with exponential backoff until it succeeds, the process
  ## exits, or `timeoutMs` (0 = forever) expires. Process exit triggers one final
  ## condition check so data flushed during shutdown can still satisfy it.
  result = false

  if initialIntervalMs <= 0:
    raise newException(ValueError, "initialIntervalMs must be positive")
  if maxIntervalMs < initialIntervalMs:
    raise newException(ValueError, "maxIntervalMs must be >= initialIntervalMs")
  if backoff <= 1.0:
    raise newException(ValueError, "backoff must be > 1.0")
  if timeoutMs < 0:
    raise newException(ValueError, "timeoutMs must be >= 0")

  let
    infinite = timeoutMs == 0
    deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)

  var delay = initialIntervalMs.float

  while true:
    if condition():
      return true

    var waitMs: int

    if infinite:
      waitMs = delay.int
    else:
      let now = getMonoTime()
      if now >= deadline:
        return false

      let remaining = (deadline - now).inMilliseconds.int
      if remaining <= 0:
        return false

      waitMs = min(delay.int, remaining)

    if process.waitForExitNonDestructive(waitMs):
      # Last-chance read of files flushed just before process exit.
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
  let condition = proc(): bool = checkLst(lstFile)
  return poll(process, condition, timeoutMs)

proc waitTmp(process: Process, deckFile: string, timeoutMs: int): bool =
  ## Waits for the `.tmp` file to appear; returns true only if found (stops
  ## early if the process exits).
  let tmpFile = changeFileExt(deckFile, "tmp")
  let condition = proc(): bool = fileExists(tmpFile)
  return poll(process, condition, timeoutMs)

# GUI readiness
proc matchesGuiWindow(
    hwnd: Handle,
    pid: int32,
    guiClasses: HashSet[string],
): bool =
  ## Returns true when `hwnd` belongs to `pid` and has a target window class.
  var windowPid: int32 = 0
  discard getWindowThreadProcessId(hwnd, addr windowPid)
  if windowPid != pid:
    return false

  var classBuffer = default(array[WindowClassBufferChars, Utf16Char])
  let className = cast[WideCString](addr classBuffer[0])
  return getClassNameW(hwnd, className, int32(WindowClassBufferChars)) > 0 and
    $className in guiClasses

proc enumCallback(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.} =
  ## EnumWindows callback: records the first window matching the target pid and
  ## class.
  let data = cast[ptr CallbackData](lParam)
  if matchesGuiWindow(hwnd, data.pid, data.guiClasses):
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

  let condition = proc(): bool =
    data.foundHwnd = 0
    discard enumWindows(enumCallback, cast[LPARAM](addr data))
    return data.foundHwnd != 0

  return poll(process, condition, timeoutMs)

# GUI minimization
proc collectCallback(hwnd: Handle, lParam: LPARAM): int32 {.stdcall.} =
  ## EnumWindows callback: collects *every* visible, titled window matching the
  ## target pid and class.
  let data = cast[ptr CollectData](lParam)
  if matchesGuiWindow(hwnd, data.pid, data.guiClasses) and
      isWindowVisible(hwnd) != 0 and
      getWindowTextLengthW(hwnd) > 0:
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

  let condition = proc(): bool =
    let windows = windowsOf(process, classes)
    if windows.len == 0:
      return false

    for hwnd in windows:
      if isIconic(hwnd) == 0:
        discard showWindow(hwnd, SW_SHOWMINNOACTIVE)
    return true

  return poll(process, condition, timeoutMs)

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
  ## Runs enabled GUI, `.lst`, and `.tmp` readiness stages in order against one
  ## shared deadline, followed by the optional fixed delay.
  ##
  ## A non-positive `timeoutMs` waits indefinitely. Returns `wrReady` when all
  ## enabled stages pass, `wrTimeout` when the deadline expires while the
  ## process is running, or `wrExited` if it exits during detection or the
  ## additional delay.
  ##
  ## `wrExited` is not by itself a failure: a run short enough to finish before
  ## detection completes reports it exactly as a crash does. Callers must
  ## consult the TRNSYS log to tell the two apart.
  if not process.running:
    return wrExited

  let deadline = getMonoTime() + initDuration(milliseconds = max(0, timeoutMs))

  template remainingMs(): int =
    if timeoutMs <= 0:
      0
    else:
      max(1, (deadline - getMonoTime()).inMilliseconds.int)

  if waitForGui:
    if not waitGui(process, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrExited

  if waitForLst:
    if not waitLst(process, deckFile, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrExited

  if waitForTmp:
    if not waitTmp(process, deckFile, timeoutMs = remainingMs()):
      return if process.running: wrTimeout else: wrExited

  if extraDelayMs > 0:
    let diedDuringDelay = poll(
      process = process,
      condition = proc(): bool = not process.running,
      timeoutMs = extraDelayMs,
    )
    if diedDuringDelay or not process.running:
      return wrExited

  return if process.running: wrReady else: wrExited
