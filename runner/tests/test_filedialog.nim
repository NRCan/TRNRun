import std/[atomics, os, unittest, winlean]

import ../src/filedialog


const
  CustomDialogTitle = "TRNRun file dialog cancellation test"
  DeckDialogTitle = "Select TRNSYS Deck File"
  WM_CLOSE = 0x0010'u32
  DialogPollAttempts = 500
  DialogPollMs = 10

var dialogObserved: Atomic[bool]

proc findWindowW(className, windowName: WideCString): Handle
  {.importc: "FindWindowW", dynlib: "user32", stdcall.}

proc postMessageW(
    window: Handle,
    message: uint32,
    wParam: uint,
    lParam: int,
): int32 {.importc: "PostMessageW", dynlib: "user32", stdcall.}

proc closeDialog(dialogKind: int) {.thread.} =
  let title =
    if dialogKind == 0:
      CustomDialogTitle
    else:
      DeckDialogTitle
  let titleBuffer = newWideCString(title)

  for _ in 0 ..< DialogPollAttempts:
    let window = findWindowW(nil, titleBuffer)
    if window != 0:
      dialogObserved.store(true)
      discard postMessageW(window, WM_CLOSE, 0, 0)
      return
    sleep(DialogPollMs)


{.push warning[ProveInit]: off, warning[Uninit]: off.}

suite "Windows file dialog integration":
  test "returns an empty path when a custom dialog is closed":
    dialogObserved.store(false)
    var closer: Thread[int]
    createThread(closer, closeDialog, 0)

    let selectedPath = openFileDialog(title = CustomDialogTitle)
    joinThread(closer)

    check dialogObserved.load()
    check selectedPath == ""

  test "opens the deck dialog and returns empty when it is closed":
    dialogObserved.store(false)
    var closer: Thread[int]
    createThread(closer, closeDialog, 1)

    let selectedPath = openDeckFileDialog()
    joinThread(closer)

    check dialogObserved.load()
    check selectedPath == ""

{.pop.}
