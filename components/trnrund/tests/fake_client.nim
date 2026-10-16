## A client that never reads stdout, for tests of the writer thread.
##
## `writeUnread` writes to a pipe with a small buffer whose read end nobody
## reads, so a write longer than the buffer blocks until `stop` cancels it.

import std/[strutils, winlean]

var unreadInput, unreadOutput: Handle ## Ends of the pipe; nobody reads `unreadOutput`.

proc openUnreadPipe*() =
  ## Opens the pipe `writeUnread` writes to. Close it with `closeUnreadPipe`.
  var attributes = SECURITY_ATTRIBUTES(
    nLength: int32(sizeof(SECURITY_ATTRIBUTES)), lpSecurityDescriptor: nil, bInheritHandle: 0
  )
  doAssert createPipe(unreadOutput, unreadInput, attributes, 512) != 0

proc closeUnreadPipe*() =
  ## Closes both ends of the pipe `openUnreadPipe` opened.
  discard closeHandle(unreadInput)
  discard closeHandle(unreadOutput)

proc writeUnread*(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## A `WriteLines` that blocks once the unread pipe is full.
  var
    text = lines.join("\n")
    count = 0'i32
  writeFile(unreadInput, addr text[0], int32(text.len), addr count, nil) != 0
