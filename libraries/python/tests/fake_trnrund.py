"""A stand-in for trnrund that answers ``DaemonProcess`` requests by their ``cmd``.

Run as ``python fake_trnrund.py [--ignore-eof] [args...]``. Each request line
gets the reply its ``cmd`` names:

=========== ==============================================================
cmd         reply
=========== ==============================================================
ready       ``ok``, with the command-line ``args``
reject      ``ok: false`` with an ``error``
bare_reject ``ok: false`` without an ``error``
notify      a ``changed`` notification at ``revision``, then ``ok``
noise       lines a client must skip, then ``ok``
mute        nothing; its reply comes before the next request's
crash       ``boom`` on stderr, then exit code 3, without replying
exit        ``ok``, then exit with ``code``, writing ``bye`` to stderr if not 0
=========== ==============================================================

It exits 0 once stdin ends, unless ``--ignore-eof`` keeps it running until
it is killed.
"""

import json
import sys
import time


def send(message: object) -> None:
    """Write one JSON line to stdout."""
    print(json.dumps(message), flush=True)


def main() -> int:
    """Answer requests until stdin ends or a command exits."""
    args = sys.argv[1:]
    muted: list[object] = []
    for line in sys.stdin:
        request = json.loads(line)
        cmd = request["cmd"]
        if cmd == "mute":
            muted.append(request["id"])
            continue
        for request_id in muted:
            send({"id": request_id, "ok": True, "late": True})
        muted.clear()
        reply: dict[str, object] = {"id": request["id"], "ok": True}
        if cmd == "ready":
            reply["args"] = args
        elif cmd == "reject":
            reply = {"id": request["id"], "ok": False, "error": "Rejected on purpose"}
        elif cmd == "bare_reject":
            reply = {"id": request["id"], "ok": False}
        elif cmd == "notify":
            send({"event": "changed", "revision": request["revision"]})
        elif cmd == "noise":
            print("not json", flush=True)
            send([1, 2, 3])
            send({"something": "else"})
            send({"event": "other"})
        elif cmd == "crash":
            print("boom", file=sys.stderr, flush=True)
            return 3
        elif cmd == "exit":
            send(reply)
            code = int(request.get("code", 0))
            if code:
                print("bye", file=sys.stderr, flush=True)
            return code
        send(reply)
    if "--ignore-eof" in args:
        time.sleep(60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
