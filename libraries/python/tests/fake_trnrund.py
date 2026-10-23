"""A stand-in for trnrund that answers ``DaemonProcess`` requests by their ``cmd``.

Run as ``python fake_trnrund.py [--protocol:N] [--ignore-eof] [args...]``.
Each request line gets the reply its ``cmd`` names:

=========== ==============================================================
cmd         reply
=========== ==============================================================
ready       ``ok``, with the command-line ``args`` and ``protocolVersion`` N, 2 by default
reject      ``ok: false`` with an ``error``
bare_reject ``ok: false`` without an ``error``
say         the request's ``line`` verbatim, which a client must refuse, then ``ok``
crash       ``boom`` on stderr, then exit code 3, without replying
exit        ``ok``, then exit with ``code``, writing ``bye`` to stderr if not 0
other       ``ok``
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
    protocol = next((int(arg.split(":")[1]) for arg in args if arg.startswith("--protocol:")), 2)
    for line in sys.stdin:
        request = json.loads(line)
        cmd = request["cmd"]
        reply: dict[str, object] = {"id": request["id"], "ok": True}
        if cmd == "ready":
            reply.update(args=args, protocolVersion=protocol)
        elif cmd == "reject":
            reply = {"id": request["id"], "ok": False, "error": "Rejected on purpose"}
        elif cmd == "bare_reject":
            reply = {"id": request["id"], "ok": False}
        elif cmd == "say":
            print(request["line"], flush=True)
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
