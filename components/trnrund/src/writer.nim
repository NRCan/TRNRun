## Writes replies and change notifications to the client on its own thread.
##
## The scheduler hands each batch's replies to `send` and goes straight back
## to work, so a client that reads slowly, or not at all, never stops the
## daemon from saving simulations. Replies are kept in request order and never
## dropped while the client reads. Notifications are merged: only the latest
## saved revision waits to be written, so unread notifications cost no memory.
## Each write puts the waiting replies first, then at most one notification.
##
## A write that fails means the client is gone. The writer then posts
## `mkClosed` to the scheduler inbox, as the stdin reader does when the client
## closes its input, and drops everything sent afterwards.
##
## `stop` gives the client a grace period to read what is left, then cancels a
## write blocked on a client that is not reading, so the daemon never waits
## for one to exit.

import std/[json, locks, winlean]
import ./messages
import ./threadstart

type
  WriteLines* = proc(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].}
    ## Writes and flushes lines (writer thread, cancellable by `stop`); false once the client left.

  Pending = object
    ## What the scheduler handed over that is not written yet.
    replies: seq[string] ## In request order.
    revision: int ## Latest saved revision.
    announced: int ## Latest revision written, or the one the client started from.
    finishing: bool ## No more sends: write what is waiting, then stop.
    stopped: bool ## A write failed or the grace period ended: write nothing more.

  Shared = object
    ## State the scheduler and the writer thread share, guarded by `lock`.
    lock: Lock
    wake: Cond ## Signalled when there is something to write or `finishing` is set.
    pending: Pending
    write: WriteLines
    inbox: ptr Channel[Message]

  Writer* = object
    ## Writes to the client on its own thread; must not move from `start` until `stop` returns.
    shared: Shared
    thread: Thread[ptr Shared]
    started: bool

const CancelPollMs = 10 ## How often `stop` retries cancelling a blocked write.

proc cancelSynchronousIo(thread: Handle): WINBOOL {.
    stdcall, dynlib: "kernel32", importc: "CancelSynchronousIo", sideEffect.}
  ## Cancels a blocking I/O call on `thread`; returns 0 when none was pending.

proc notification(revision: int): string =
  ## The line announcing that `revision` was saved.
  $(%*{"event": "changed", "revision": revision})

proc take(shared: ptr Shared): seq[string] =
  ## Waits for something to write and takes it; nothing once stopped or finished.
  result = @[]
  withLock shared.lock:
    while shared.pending.replies.len == 0 and
        shared.pending.revision <= shared.pending.announced and
        not shared.pending.finishing:
      wait(shared.wake, shared.lock)
    if shared.pending.stopped:
      return
    swap(result, shared.pending.replies)
    if shared.pending.revision > shared.pending.announced:
      shared.pending.announced = shared.pending.revision
      result.add(notification(shared.pending.revision))

proc runWriter(shared: ptr Shared) {.thread.} =
  ## Writes until finished, stopped, or the client can no longer be written to.
  while true:
    let lines = take(shared)
    if lines.len == 0:
      break
    if not shared.write(lines):
      withLock shared.lock:
        shared.pending.stopped = true
        shared.pending.replies.setLen(0)
      shared.inbox[].send(Message(kind: mkClosed))
      break

# Public API

proc start*(
    writer: var Writer, write: WriteLines, inbox: ptr Channel[Message], revision: int
) =
  ## Starts the thread writing with `write`, announcing only revisions after `revision`.
  writer.shared =
    Shared(pending: Pending(revision: revision, announced: revision), write: write, inbox: inbox)
  initLock(writer.shared.lock)
  initCond(writer.shared.wake)
  writer.thread.startThread(runWriter, addr writer.shared)
  writer.started = true

proc send*(writer: var Writer, replies: sink seq[string], revision: int) =
  ## Hands over one batch's replies and the revision it saved; returns at once.
  withLock writer.shared.lock:
    let pending = addr writer.shared.pending
    if not pending.stopped and not pending.finishing:
      pending.replies.add(replies)
      pending.revision = max(pending.revision, revision)
      signal(writer.shared.wake)

proc stop*(writer: var Writer, graceMs: int32) =
  ## Writes what was sent for up to `graceMs`, then cancels any blocked write and joins the thread.
  if not writer.started:
    return
  withLock writer.shared.lock:
    writer.shared.pending.finishing = true
    signal(writer.shared.wake)
  let thread = handle(writer.thread)
  if waitForSingleObject(thread, graceMs) == WAIT_TIMEOUT:
    withLock writer.shared.lock:
      writer.shared.pending.stopped = true
    # Retried: a write that starts right after a cancel blocks again.
    while waitForSingleObject(thread, CancelPollMs) == WAIT_TIMEOUT:
      discard cancelSynchronousIo(thread)
  joinThread(writer.thread)
  deinitCond(writer.shared.wake)
  deinitLock(writer.shared.lock)
  writer.started = false
