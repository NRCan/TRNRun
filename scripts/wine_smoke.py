#!/usr/bin/env python3
r"""Phase 0 Wine smoke test: does TRNSYS + trnrun.exe + trnrund.exe work under Wine on Linux?

Standard library only; run it with any Python 3.10+ on the Linux host, not inside Wine.

Prerequisites
-------------
- Wine on PATH (or --wine), and a prefix (WINEPREFIX, default ~/.wine) with TRNSYS
  installed, by default at C:\TRNSYS18\Exe\TrnEXE64.exe.
- Type3830 installed in that TRNSYS for the default *_w_tracking decks.
- trnrun.exe and trnrund.exe in --bin (default: libraries/python/trnrun/bin).

Usage
-----
    python3 scripts/wine_smoke.py
    python3 scripts/wine_smoke.py --trnexe 'C:\TRNSYS17\Exe\TrnEXE64.exe' --workers 4
    xvfb-run -a python3 scripts/wine_smoke.py      # headless, with a virtual display

Each check prints PASS, WARN, FAIL or SKIP; the exit code is 1 if any check failed.
Deck copies made by the concurrency check are deleted afterwards, with their outputs.
"""

import argparse
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable
from pathlib import Path, PureWindowsPath

REPO = Path(__file__).resolve().parent.parent
PASS, WARN, FAIL, SKIP = "PASS", "WARN", "FAIL", "SKIP"


class CheckFailed(Exception):
    """A check found a problem; the message says which."""


class Skipped(Exception):
    """A check could not run, such as when one it depends on failed."""


# ---------------------------------------------------------------- paths


def wine_prefix() -> Path:
    return Path(os.environ.get("WINEPREFIX", Path.home() / ".wine"))


def to_windows(path: Path) -> str:
    r"""/home/a/deck.dck -> Z:\home\a\deck.dck (Wine maps Z: to /)."""
    return "Z:" + str(path.resolve()).replace("/", "\\")


def to_unix(path: str) -> Path:
    r"""C:\TRNSYS18\Exe\TrnEXE64.exe -> $WINEPREFIX/dosdevices/c:/TRNSYS18/Exe/TrnEXE64.exe."""
    drive, rest = path[0].lower(), path[2:].lstrip("\\")
    return wine_prefix() / "dosdevices" / f"{drive}:" / rest.replace("\\", "/")


# ---------------------------------------------------------------- processes


def wine_env(*, quiet: bool = True) -> dict[str, str]:
    env = dict(os.environ)
    env["WINEDLLOVERRIDES"] = "mscoree,mshtml="  # No Mono or Gecko install dialog on a fresh prefix.
    if quiet:
        env["WINEDEBUG"] = "-all"
    else:
        env.pop("WINEDEBUG", None)
    return env


def wine_pids(*exes: str) -> set[int]:
    """Linux pids of Wine processes running one of ``exes``, such as ``trnrun``; ``trnexe`` matches TrnEXE64 too.

    Only the program names are matched, never other arguments: trnrun.exe's own
    ``--trnexePath:...TrnEXE64.exe`` must not make it look like TrnEXE.
    """
    found = set()
    for proc in Path("/proc").iterdir():
        if not proc.name.isdigit():
            continue
        try:
            argv = (proc / "cmdline").read_bytes().decode(errors="replace").split("\0")
        except OSError:
            continue
        # Wine shows the Windows path as argv[0]; a `wine X.exe` not yet exec'd has it as argv[1].
        stems = {PureWindowsPath(arg.replace("/", "\\")).stem.lower() for arg in argv[:2] if arg.lower().endswith(".exe")}
        if any(stem == exe or (exe == "trnexe" and stem.startswith("trnexe")) for stem in stems for exe in exes):
            found.add(int(proc.name))
    return found


def kill_pids(pids: set[int]) -> None:
    for pid in pids:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def wait_until(predicate: Callable[[], bool], timeout: float, interval: float = 0.5) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class Daemon:
    """``wine trnrund.exe`` with a line-based JSON client that never blocks forever."""

    def __init__(self, ctx: "Context", workers: int) -> None:
        args = [
            ctx.wine,
            str(ctx.bin / "trnrund.exe"),
            f"--trnrun:{to_windows(ctx.bin / 'trnrun.exe')}",
            f"--workers:{workers}",
        ]
        self.process = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            env=wine_env(),
        )
        self.lines: queue.Queue[str | None] = queue.Queue()
        self.stderr: list[str] = []
        self.junk: list[str] = []
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _read_stdout(self) -> None:
        assert self.process.stdout
        for line in self.process.stdout:
            self.lines.put(line)
        self.lines.put(None)

    def _read_stderr(self) -> None:
        assert self.process.stderr
        for line in self.process.stderr:
            self.stderr.append(line.rstrip())

    def request(self, request: dict, timeout: float = 60) -> dict:
        assert self.process.stdin
        try:
            self.process.stdin.write(json.dumps(request) + "\n")
            self.process.stdin.flush()
        except OSError as error:
            raise CheckFailed(f"trnrund stdin closed: {error}; stderr: {self.stderr_tail()}") from error
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.0, deadline - time.monotonic()))
            except queue.Empty:
                raise CheckFailed(f"no reply to {request['cmd']} within {timeout:.0f}s") from None
            if line is None:
                raise CheckFailed(f"trnrund exited (code {self.process.poll()}); stderr: {self.stderr_tail()}")
            try:
                response = json.loads(line)
            except json.JSONDecodeError:
                self.junk.append(line.rstrip())  # Non-JSON on stdout: would break every client.
                continue
            if not response.get("ok"):
                raise CheckFailed(f"trnrund refused {request['cmd']}: {response.get('error')}")
            return response

    def simulation(self, sim_id: int) -> dict:
        return self.request({"cmd": "simulation", "simId": sim_id})["simulation"]

    def wait_finished(self, sim_ids: list[int], timeout: float) -> list[dict]:
        sims: list[dict] = []

        def done() -> bool:
            nonlocal sims
            sims = [self.simulation(sim_id) for sim_id in sim_ids]
            return all(sim["state"] == "FINISHED" for sim in sims)

        if not wait_until(done, timeout, 1.0):
            states = ", ".join(f"{s['simId']}={s['state']}/{s['trnrunStatus']}" for s in sims)
            raise CheckFailed(f"not finished within {timeout:.0f}s: {states}")
        return sims

    def stderr_tail(self, lines: int = 5) -> str:
        return " | ".join(self.stderr[-lines:]) or "(empty)"

    def close(self, timeout: float = 20) -> int | None:
        """Close stdin, so trnrund cancels its runs and exits; return its exit code, None if it hung."""
        try:
            assert self.process.stdin
            self.process.stdin.close()
        except OSError:
            pass
        try:
            return self.process.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def kill(self) -> None:
        self.process.kill()
        self.process.wait()


# ---------------------------------------------------------------- context and runner helpers


class Context:
    def __init__(self, args: argparse.Namespace) -> None:
        self.wine: str = args.wine
        self.bin: Path = args.bin.resolve()
        self.trnexe: str = args.trnexe
        self.deck: Path = args.deck.resolve()
        self.slow_deck: Path = args.slow_deck.resolve()
        self.workers: int = args.workers
        self.timeout: float = args.timeout
        self.headless = not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
        self.baseline = wine_pids("trnexe", "trnrun", "trnrund")  # Not ours; never touched.
        self.failed: set[str] = set()
        # TRNRun options for every run; trnrun-no-waitforgui adds waitForGui false when that is what works.
        # watchTmp is TRNRun's default; explicit so a default change cannot hide missing progress.
        self.options: dict[str, object] = {"trnexePath": self.trnexe, "watchTmp": True}
        if args.write_events:
            self.options["writeEvents"] = True  # <deck>.jsonl beside each deck, for a look after the run.

    def leftovers(self) -> set[int]:
        return wine_pids("trnexe", "trnrun", "trnrund") - self.baseline

    def needs(self, *checks: str) -> None:
        failed = [check for check in checks if check in self.failed]
        if failed:
            raise Skipped(f"needs {', '.join(failed)}")


def run_trnrun(ctx: Context, *options: str, quiet: bool = True, merge_stderr: bool = False):
    """Run ``wine trnrun.exe`` on the fast deck; return (exit code, events, non-JSON stdout lines, stderr)."""
    flags = [f"--{key}:{str(value).lower() if isinstance(value, bool) else value}" for key, value in ctx.options.items()]
    args = [ctx.wine, str(ctx.bin / "trnrun.exe"), to_windows(ctx.deck), *flags, *options]
    try:
        result = subprocess.run(
            args,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            env=wine_env(quiet=quiet),
            timeout=ctx.timeout,
        )
    except subprocess.TimeoutExpired:
        kill_pids(ctx.leftovers())
        raise CheckFailed(f"trnrun.exe did not exit within {ctx.timeout:.0f}s") from None
    events, junk = [], []
    for line in result.stdout.splitlines():
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            if line.strip():
                junk.append(line)
    return result.returncode, events, junk, (result.stderr or "").strip()


def final_status(events: list[dict]) -> tuple[str | None, str | None]:
    statuses = [event for event in events if event.get("kind") == "STATUS"]
    return (statuses[-1]["status"], statuses[-1].get("message")) if statuses else (None, None)


def judge_run(code: int, events: list[dict], junk: list[str], stderr: str) -> tuple[str, int]:
    """Raise CheckFailed unless the run ended DONE with exit code 0 and clean stdout; return a summary and PROGRESS count."""
    status, message = final_status(events)
    problems = []
    if junk:
        problems.append(f"{len(junk)} non-JSON stdout line(s), first: {junk[0][:120]!r}")
    if status != "DONE":
        problems.append(f"final status {status} ({message})")
    if code != 0:
        problems.append(f"exit code {code}")
    if problems:
        tail = stderr.splitlines()[-3:]
        raise CheckFailed("; ".join(problems) + (f"; stderr: {' | '.join(tail)}" if tail else ""))
    progress = sum(event.get("kind") == "PROGRESS" for event in events)
    return f"DONE, {len(events)} events, {progress} PROGRESS", progress


# ---------------------------------------------------------------- checks


def check_environment(ctx: Context) -> tuple[str, str]:
    if not shutil.which(ctx.wine):
        raise CheckFailed(f"{ctx.wine!r} not found; install Wine or pass --wine")
    version = subprocess.run([ctx.wine, "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    missing = [str(path) for path in (ctx.bin / "trnrun.exe", ctx.bin / "trnrund.exe", ctx.deck, ctx.slow_deck)
               if not path.is_file()]
    trnexe = to_unix(ctx.trnexe)
    if not trnexe.is_file():
        missing.append(f"{ctx.trnexe} (looked for {trnexe})")
    if missing:
        raise CheckFailed("missing: " + ", ".join(missing))
    display = "headless" if ctx.headless else f"display {os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY')}"
    return PASS, f"{version}, prefix {wine_prefix()}, {display}"


def check_versions(ctx: Context) -> tuple[str, str]:
    ctx.needs("environment")
    found = []
    for exe in ("trnrun.exe", "trnrund.exe"):
        # Generous timeout: the first Wine start in a fresh prefix boots it.
        result = subprocess.run([ctx.wine, str(ctx.bin / exe), "--version"], capture_output=True, text=True,
                                env=wine_env(), timeout=180)
        lines = result.stdout.strip().splitlines()
        if result.returncode != 0 or len(lines) != 1:
            raise CheckFailed(f"{exe} --version: code {result.returncode}, stdout {result.stdout!r}, "
                              f"stderr {result.stderr.strip()[-200:]!r}")
        found.append(f"{exe} {lines[0]}")
    return PASS, ", ".join(found)


def check_trnexe_direct(ctx: Context) -> tuple[str, str]:
    """TRNSYS alone under Wine: runs, licence accepted, writes its .lst."""
    ctx.needs("versions")
    lst = ctx.deck.with_suffix(".lst")
    before = lst.stat().st_mtime if lst.exists() else 0.0
    started = time.monotonic()
    try:
        result = subprocess.run([ctx.wine, str(to_unix(ctx.trnexe)), to_windows(ctx.deck), "/h"],
                                capture_output=True, text=True, errors="replace", env=wine_env(),
                                timeout=ctx.timeout)
    except subprocess.TimeoutExpired:
        kill_pids(ctx.leftovers())
        raise CheckFailed(f"TrnEXE did not exit within {ctx.timeout:.0f}s (licence dialog? use a display to see)") from None
    if not lst.exists() or lst.stat().st_mtime <= before:
        raise CheckFailed(f"exit code {result.returncode} but {lst.name} was not written")
    if result.returncode != 0:
        return WARN, f"exit code {result.returncode}; {lst.name} written; check it for errors"
    return PASS, f"exit 0 in {time.monotonic() - started:.1f}s, {lst.name} written"


def check_trnrun_events(ctx: Context) -> tuple[str, str]:
    """trnrun.exe with default settings (guiVisibility hidden, waitForGui true), WINEDEBUG=-all."""
    ctx.needs("versions")
    summary, progress = judge_run(*run_trnrun(ctx))
    if not progress:
        # The default decks have Type3830, so no progress means TRNSYS quit early, which TRNRun reports as DONE.
        raise CheckFailed(summary + "; no progress: TRNSYS likely quit early (no display?) or Type3830 is missing")
    return PASS, summary


def check_trnrun_without_waitforgui(ctx: Context) -> tuple[str, str]:
    """Only run when the default run failed: is EnumWindows-based GUI detection the problem?

    If this passes, the remaining checks keep ``waitForGui`` false, so they test everything else.
    """
    if "trnrun-events" not in ctx.failed:
        raise Skipped("trnrun-events did not fail")
    summary, _ = judge_run(*run_trnrun(ctx, "--waitForGui:false"))
    ctx.options["waitForGui"] = False
    ctx.failed.discard("trnrun-events")
    return WARN, f"{summary}; GUI detection fails here, so default waitForGui to false under Wine" + (
        " or run under xvfb-run" if ctx.headless else "") + "; later checks use waitForGui false"


def check_trnrun_minimized(ctx: Context) -> tuple[str, str]:
    """guiVisibility minAuto: TRNSYS window found and minimized via user32 (EnumWindows, ShowWindow).

    minAuto, not min: min keeps the TRNSYS window open after the run, waiting for a user to close it.
    """
    ctx.needs("trnrun-events")
    if ctx.headless:
        raise Skipped("no display; rerun under xvfb-run to test window handling")
    return PASS, judge_run(*run_trnrun(ctx, "--guiVisibility:minAuto", "--waitForGui:true"))[0]


def check_wine_noise(ctx: Context) -> tuple[str, str]:
    """Without WINEDEBUG=-all, with stderr merged into stdout as trnrund does: is the event stream still clean?"""
    ctx.needs("trnrun-events")
    code, events, junk, _ = run_trnrun(ctx, quiet=False, merge_stderr=True)
    if junk:
        return WARN, (f"{len(junk)} non-JSON line(s), such as {junk[0][:100]!r}: the libraries must set "
                      "WINEDEBUG=-all")
    return PASS, f"clean even without WINEDEBUG ({len(events)} events, exit {code})"


def check_keep_awake(ctx: Context) -> tuple[str, str]:
    ctx.needs("trnrun-events")
    summary, _ = judge_run(*run_trnrun(ctx, "--keepAwake:true"))
    return WARN, f"{summary}; keepAwake does not fail, but it cannot stop the Linux host sleeping"


def check_daemon_single(ctx: Context) -> tuple[str, str]:
    ctx.needs("trnrun-events")
    daemon = Daemon(ctx, workers=1)
    try:
        version = daemon.request({"cmd": "ready"}, timeout=180)["version"]
        sim_id = daemon.request({"cmd": "add", "deckFile": to_windows(ctx.deck),
                                 "trnrunOptions": ctx.options})["simId"]
        (sim,) = daemon.wait_finished([sim_id], ctx.timeout)
        if not sim["succeeded"]:
            raise CheckFailed(f"{sim['trnrunStatus']}: {sim['trnrunMessage'] or sim['error']} (exit {sim['exitCode']})")
        if (sim["percent"] or 0) < 0.99:
            raise CheckFailed(f"succeeded at {sim['percent']} progress: TRNSYS likely quit early, reported as DONE")
        if daemon.junk:
            raise CheckFailed(f"non-JSON on trnrund stdout: {daemon.junk[0][:120]!r}")
        return PASS, f"trnrund {version}; deckFile echoed as {sim['deckFile']!r}"
    finally:
        if daemon.close() is None:
            daemon.kill()


def check_daemon_concurrent(ctx: Context) -> tuple[str, str]:
    """``workers`` copies at once: exercises the Global\\TRNRun_LaunchMutex under Wine."""
    ctx.needs("daemon-single")
    copies = [ctx.deck.with_name(f"{ctx.deck.stem}_wine{i}{ctx.deck.suffix}") for i in range(1, ctx.workers + 1)]
    for copy in copies:
        shutil.copyfile(ctx.deck, copy)
    daemon = Daemon(ctx, workers=ctx.workers)
    try:
        daemon.request({"cmd": "ready"}, timeout=180)
        sim_ids = [daemon.request({"cmd": "add", "deckFile": to_windows(copy),
                                   "trnrunOptions": ctx.options})["simId"] for copy in copies]
        sims = daemon.wait_finished(sim_ids, ctx.timeout * 2)
        failed = [f"{PureWindowsPath(s['deckFile']).name}: {s['trnrunStatus']} ({s['trnrunMessage'] or s['error']})"
                  for s in sims if not s["succeeded"] or (s["percent"] or 0) < 0.99]
        if failed:
            raise CheckFailed(f"{len(failed)}/{len(sims)} failed: " + "; ".join(failed))
        return PASS, f"{len(sims)} decks at once, all succeeded"
    finally:
        if daemon.close() is None:
            daemon.kill()
        for copy in copies:
            for output in copy.parent.glob(f"{copy.stem}.*"):  # The copy and the outputs named after it.
                output.unlink(missing_ok=True)


def start_slow_run(ctx: Context) -> Daemon:
    """trnrund running the slow deck, with TrnEXE up; raises CheckFailed if it never gets there."""
    daemon = Daemon(ctx, workers=1)

    def running() -> bool:
        sim = daemon.simulation(sim_id)
        if sim["state"] == "FINISHED":
            raise CheckFailed(f"slow deck finished before the test could interrupt it ({sim['trnrunStatus']}); "
                              "pass a longer --slow-deck")
        return sim["trnrunStatus"] == "RUNNING" and bool(wine_pids("trnexe") - ctx.baseline)

    try:
        daemon.request({"cmd": "ready"}, timeout=180)
        sim_id = daemon.request({"cmd": "add", "deckFile": to_windows(ctx.slow_deck),
                                 "trnrunOptions": ctx.options})["simId"]
        if not wait_until(running, 300):
            raise CheckFailed("slow deck never reached RUNNING with a TrnEXE process")
    except BaseException:
        daemon.kill()
        kill_pids(ctx.leftovers())
        raise
    time.sleep(2)  # Let it settle into the run.
    return daemon


def check_daemon_close(ctx: Context) -> tuple[str, str]:
    """Normal shutdown: closing stdin makes trnrund kill its runs and exit."""
    ctx.needs("daemon-single")
    daemon = start_slow_run(ctx)
    code = daemon.close()
    if code is None:
        daemon.kill()
        raise CheckFailed("trnrund did not exit within 20s of stdin closing")
    if not wait_until(lambda: not ctx.leftovers(), 15):
        left = ctx.leftovers()
        kill_pids(left)
        raise CheckFailed(f"trnrund exited ({code}) but left {len(left)} process(es) running")
    return PASS, f"trnrund exited with {code}; TrnEXE and trnrun gone"


def check_daemon_killed(ctx: Context) -> tuple[str, str]:
    """Crash: SIGKILL trnrund; the Job Object (kill on close) should take TrnEXE down with it."""
    ctx.needs("daemon-single")
    daemon = start_slow_run(ctx)
    os.kill(daemon.process.pid, signal.SIGKILL)
    kill_pids(wine_pids("trnrund.exe") - ctx.baseline)  # In case `wine` did not exec into trnrund itself.
    daemon.process.wait()
    if wait_until(lambda: not ctx.leftovers(), 15):
        return PASS, "SIGKILL on trnrund took trnrun and TrnEXE with it"
    left = ctx.leftovers()
    kill_pids(left)
    raise CheckFailed(f"{len(left)} orphan process(es) after SIGKILL: Wine's Job Object kill-on-close did not fire; "
                      "the libraries need their own process-group kill")


CHECKS: list[tuple[str, Callable[[Context], tuple[str, str]]]] = [
    ("environment", check_environment),
    ("versions", check_versions),
    ("trnexe-direct", check_trnexe_direct),
    ("trnrun-events", check_trnrun_events),
    ("trnrun-no-waitforgui", check_trnrun_without_waitforgui),
    ("trnrun-minimized", check_trnrun_minimized),
    ("wine-noise", check_wine_noise),
    ("keep-awake", check_keep_awake),
    ("daemon-single", check_daemon_single),
    ("daemon-concurrent", check_daemon_concurrent),
    ("daemon-close", check_daemon_close),
    ("daemon-killed", check_daemon_killed),
]


# ---------------------------------------------------------------- main


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--wine", default=os.environ.get("TRNRUN_WINE", "wine"), help="Wine command (default: wine)")
    parser.add_argument("--bin", type=Path, default=REPO / "libraries/python/trnrun/bin",
                        help="directory with trnrun.exe and trnrund.exe")
    parser.add_argument("--trnexe", default=r"C:\TRNSYS18\Exe\TrnEXE64.exe", help="TrnEXE path inside the prefix")
    parser.add_argument("--deck", type=Path, default=REPO / "decks/slow_wo_plot_w_tracking.dck",
                        help="short deck for the run checks")
    parser.add_argument("--slow-deck", type=Path, default=REPO / "decks/slow_wo_plot_w_tracking.dck",
                        help="deck that runs long enough to be interrupted")
    parser.add_argument("--workers", type=int, default=3, help="decks run at once by daemon-concurrent")
    parser.add_argument("--timeout", type=float, default=600, help="seconds one deck may take")
    parser.add_argument("--write-events", action="store_true",
                        help="pass writeEvents to every TRNRun run, so each writes its events to a .jsonl beside its deck")
    parser.add_argument("--only", nargs="+", choices=[name for name, _ in CHECKS], help="run only these checks")
    args = parser.parse_args()

    if sys.platform != "linux":
        print("Run this on the Linux host, not on Windows or inside Wine.", file=sys.stderr)
        return 2

    ctx = Context(args)
    results: list[tuple[str, str, str]] = []
    for name, check in CHECKS:
        if args.only and name not in args.only:
            continue
        print(f"[....] {name}", end="", flush=True)
        started = time.monotonic()
        try:
            status, detail = check(ctx)
        except Skipped as reason:
            status, detail = SKIP, str(reason)
        except CheckFailed as error:
            status, detail = FAIL, str(error)
        except Exception as error:  # A bug or an environment surprise: report it, keep going.
            status, detail = FAIL, f"{type(error).__name__}: {error}"
        if status == FAIL:
            ctx.failed.add(name)
        print(f"\r[{status}] {name} ({time.monotonic() - started:.0f}s): {detail}")
        results.append((name, status, detail))

    left = ctx.leftovers()
    if left:
        print(f"Killing {len(left)} leftover process(es): {sorted(left)}")
        kill_pids(left)

    counts = {status: sum(r[1] == status for r in results) for status in (PASS, WARN, FAIL, SKIP)}
    print("\n" + ", ".join(f"{count} {status}" for status, count in counts.items()))
    return 1 if counts[FAIL] else 0


if __name__ == "__main__":
    sys.exit(main())
