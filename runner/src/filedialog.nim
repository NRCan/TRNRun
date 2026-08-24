## Provides native Windows file pickers for TRNSYS input files.
##
## `openFileDialog` accepts Win32 `\0`-delimited filter pairs, while
## `openDeckFileDialog` supplies deck-specific filters. Cancellation returns
## `""` rather than raising.

import std/winlean

# Win32 API
const
  FileBufferChars = 1024
  OFN_PATHMUSTEXIST = 0x00000800'u32
  OFN_FILEMUSTEXIST = 0x00001000'u32

type OPENFILENAMEW {.pure.} = object
  lStructSize: uint32
  hwndOwner: Handle
  hInstance: Handle
  lpstrFilter: WideCString
  lpstrCustomFilter: WideCString
  nMaxCustFilter: uint32
  nFilterIndex: uint32
  lpstrFile: WideCString
  nMaxFile: uint32
  lpstrFileTitle: WideCString
  nMaxFileTitle: uint32
  lpstrInitialDir: WideCString
  lpstrTitle: WideCString
  flags: uint32
  nFileOffset: uint16
  nFileExtension: uint16
  lpstrDefExt: WideCString
  lCustData: int
  lpfnHook: pointer
  lpTemplateName: WideCString
  pvReserved: pointer
  dwReserved: uint32
  flagsEx: uint32

proc getOpenFileNameW(p: ptr OPENFILENAMEW): int32
  {.importc: "GetOpenFileNameW", dynlib: "comdlg32", stdcall.}

# Public API
proc openFileDialog*(
    title: string = "Open File", filter: string = "All Files\0*.*\0"
): string =
  ## Shows the native Windows file picker.
  ##
  ## `filter` is a `\0`-delimited sequence of Win32 display-name and pattern
  ## pairs, for example `"Text Files\0*.txt\0All Files\0*.*\0"`.
  ## Returns the selected absolute path, or `""` if the user cancels.
  var fileBuffer = newWideCString(FileBufferChars)
  let
    filterBuffer = newWideCString(filter & "\0")
    titleBuffer = newWideCString(title)

  var dialog = OPENFILENAMEW(
    lStructSize: uint32(sizeof(OPENFILENAMEW)),
    lpstrFile: fileBuffer,
    nMaxFile: uint32(FileBufferChars),
    lpstrFilter: filterBuffer,
    lpstrTitle: titleBuffer,
    flags: OFN_PATHMUSTEXIST or OFN_FILEMUSTEXIST,
  )

  if getOpenFileNameW(addr dialog) == 0:
    return ""

  $fileBuffer

proc openDeckFileDialog*(): string =
  ## Opens a file picker pre-configured for TRNSYS deck files (`.dck`, `.trd`).
  openFileDialog(
    title = "Select TRNSYS Deck File",
    filter =
      "Standard File (*.DCK)\0*.dck\0" &
      "TRNSED File (*.TRD)\0*.trd\0" &
      "All files (*.*)\0*.*\0",
  )
