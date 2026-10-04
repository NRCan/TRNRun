## Forwards stdin request lines to the daemon from a dedicated thread.
##
## Reads the raw Win32 handle rather than the C `stdin` stream. A thread blocked
## in C stdio holds the stream lock, and process exit locks every stream to
## flush it, so a daemon shut down by request would hang until its parent
## closed stdin. `ReadFile` holds no such lock; exit simply ends the thread.

when not defined(windows):
  {.error: "input.nim is Windows-only.".}

import std/winlean
import ./messages


proc readInput*(inbox: ptr Channel[Message]) {.thread.} =
  ## Posts each non-empty line, without its line ending, until EOF or a read
  ## error, then posts `mkInputClosed`.
  let handle = getStdHandle(STD_INPUT_HANDLE)
  var
    buffer = default(array[4096, char])
    count = 0'i32
    line = ""

  while readFile(handle, addr buffer[0], int32(buffer.len), addr count, nil) != 0 and
      count > 0:
    for index in 0 ..< int(count):
      if buffer[index] != '\n':
        line.add(buffer[index])
        continue

      if line.len > 0 and line[^1] == '\r':
        line.setLen(line.len - 1)
      if line.len > 0:
        inbox[].send(Message(kind: mkCommand, line: line))
      line.setLen(0)

  if line.len > 0:
    inbox[].send(Message(kind: mkCommand, line: line))

  inbox[].send(Message(kind: mkInputClosed))
