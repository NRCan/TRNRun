## Native Windows file-picker dialogs for selecting TRNSYS input files.
##
## Wraps `GetOpenFileNameW` from `comdlg32` to show the standard Windows
## "Open File" dialog.
##
## Two procs are exported:
##
## - `openFileDialog` - general-purpose picker; caller supplies the title
##   and a `\0`-delimited filter string in the Win32 `OPENFILENAME` format
##   (e.g. `"Text Files\0*.txt\0All Files\0*.*\0"`).
## - `openDeckFileDialog` - convenience wrapper pre-configured for TRNSYS
##   deck files (`.dck`, `.trd`).
##
## Both return the chosen path as a `string`, or `""` if the user cancels
## or closes the dialog. No exception is raised on cancellation.

import std/winlean

# ---------------------------------------------------------------------------
# Win32 API
# ---------------------------------------------------------------------------
const
  OFN_PATHMUSTEXIST = 0x00000800'i32
  OFN_FILEMUSTEXIST = 0x00001000'i32

type
  OPENFILENAMEW {.pure.} = object
    lStructSize: int32
    hwndOwner: Handle
    hInstance: Handle
    lpstrFilter: WideCString
    lpstrCustomFilter: WideCString
    nMaxCustFilter: int32
    nFilterIndex: int32
    lpstrFile: WideCString
    nMaxFile: int32
    lpstrFileTitle: WideCString
    nMaxFileTitle: int32
    lpstrInitialDir: WideCString
    lpstrTitle: WideCString
    flags: int32
    nFileOffset: int16
    nFileExtension: int16
    lpstrDefExt: WideCString
    lCustData: int
    lpfnHook: pointer
    lpTemplateName: WideCString
    pvReserved: pointer
    dwReserved: int32
    flagsEx: int32

proc getOpenFileNameW(p: ptr OPENFILENAMEW): int32
  {.importc: "GetOpenFileNameW", dynlib: "comdlg32", stdcall.}

# ---------------------------------------------------------------------------
# Public Interface
# ---------------------------------------------------------------------------
proc openFileDialog*(
    title:  string = "Open File",
    filter: string = "All Files\0*.*\0"
): string =
  var buf = newWideCString(newString(1024))

  var ofn = OPENFILENAMEW(
    lStructSize: int32(sizeof(OPENFILENAMEW)),
    lpstrFile: buf,
    nMaxFile: 1024,
    lpstrFilter: newWideCString(filter & "\0"),
    lpstrTitle: newWideCString(title),
    lpstrDefExt: nil,
    flags: OFN_PATHMUSTEXIST or OFN_FILEMUSTEXIST
  )

  result =
    if getOpenFileNameW(addr ofn) != 0:
      $buf
    else:
      ""

proc openDeckFileDialog*(): string =
  openFileDialog(
    title  = "Select TRNSYS Deck File",
    filter =
      "Standard File (*.DCK)\0*.dck\0" &
      "TRNSED File (*.TRD)\0*.trd\0" &
      "All files (*.*)\0*.*\0"
  )
