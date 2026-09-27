"""Ad-hoc smoke test for the threaded manager. Run directly, then delete."""

from __future__ import annotations

import json
import threading
import time

from trnrun import SimulationConfig, SimulationManager
from trnrun import manager as manager_module


class FakeQueue:
    def __init__(self, executable, max_concurrent, on_line, on_eof):
        self.executable = executable
        self.max_concurrent = max_concurrent
        self.on_line = on_line
        self.on_eof = on_eof
        self.sent: list[dict[str, object]] = []
        self.killed = 0

    def send(self, request):
        self.sent.append(request)

    def shutdown(self):
        self.killed += 1
        self.on_eof()


def line(**fields) -> str:
    return json.dumps(fields) + "\n"


def main() -> None:
    fakes: list[FakeQueue] = []
    manager_module.QueueProcess = lambda *a: fakes.append(FakeQueue(*a)) or fakes[-1]  # type: ignore[assignment]

    config = SimulationConfig(trnrun_path=__file__, trnexe_path=__file__)
    mgr = SimulationManager(max_concurrent=2, refresh_interval=0)
    queue = fakes[0]

    # --- submit is non-blocking and registers immediately -------------
    sim = mgr.submit(__file__, config)
    assert not sim.is_accepted, "submit must not block on acceptance"
    assert mgr.simulations == [sim], "unaccepted runs must still be listed"
    assert mgr.has_active_runs
    assert queue.sent[0]["runID"] == "1"
    print("ok: submit returns immediately with the run registered")

    # --- state advances with no manager call at all -------------------
    queue.on_line(line(kind="QUEUE", event="ACCEPTED", timestamp="t", runID="1"))
    queue.on_line(line(kind="PROGRESS", time=5.0, percent=0.25, elapsed=10.0, eta=30.0, timestamp="t", runID="1"))
    assert sim.is_accepted
    assert sim.percent == 0.25, sim.percent
    print("ok: polling sees updates without calling into the manager")

    # --- coherent multi-field read under the public lock --------------
    with sim.lock:
        snapshot = (sim.percent, sim.status, sim.is_finished)
    assert snapshot == (0.25, None, False), snapshot
    print("ok: sim.lock gives a coherent multi-field read")

    # --- logs and counters --------------------------------------------
    queue.on_line(line(kind="LOG", severity="Warning", timestamp="t", message="hmm", runID="1"))
    queue.on_line(line(kind="LOG", severity="Fatal", timestamp="t", message="bad", runID="1"))
    assert (sim.notices, sim.warnings, sim.fatals, sim.log_count) == (0, 1, 1, 2)
    assert len(sim.logs) == 2
    print("ok: log history and severity counters")

    # --- wait() blocks on a real thread, then returns ------------------
    def finish_later() -> None:
        time.sleep(0.15)
        queue.on_line(line(kind="STATUS", status="DONE", message="", timestamp="t", runID="1"))
        queue.on_line(line(kind="QUEUE", event="COMPLETED", timestamp="t", runID="1", exitCode=0))

    assert mgr.wait(timeout=0.02) is False, "wait must honour its timeout"
    worker = threading.Thread(target=finish_later)
    worker.start()
    started = time.monotonic()
    assert mgr.wait(timeout=5.0) is True
    worker.join()
    assert 0.1 < time.monotonic() - started < 2.0
    assert sim.succeeded and sim.is_finished
    assert mgr.succeeded == [sim] and mgr.failed == []
    assert not mgr.has_active_runs
    print("ok: wait() blocks until completion and reports success")

    # --- malformed and unknown lines are ignored ----------------------
    queue.on_line("not json at all\n")
    queue.on_line(line(kind="STATUS", status="RUNNING", message="", timestamp="t", runID="999"))
    queue.on_line(line(kind="STATUS", status="ERROR", message="", timestamp="t", runID="1"))
    assert sim.succeeded, "events after COMPLETED must be ignored"
    print("ok: malformed, unknown, and post-completion events are dropped")

    # --- follow() yields updates --------------------------------------
    second = mgr.submit(__file__, config)
    seen: list[int] = []

    def drive() -> None:
        time.sleep(0.1)
        queue.on_line(line(kind="QUEUE", event="ACCEPTED", timestamp="t", runID="2"))
        queue.on_line(line(kind="QUEUE", event="COMPLETED", timestamp="t", runID="2", exitCode=1))

    driver = threading.Thread(target=drive)
    driver.start()
    for updated in mgr.follow(second):
        seen.append(updated.id)
    driver.join()
    assert seen == [2, 2], seen
    assert second.is_finished and not second.succeeded
    print("ok: follow() yields only the selected run and stops at completion")

    # --- a display failure faults without stalling the fold -----------
    boom = RuntimeError("display exploded")

    class ExplodingDisplay:
        def simulation_started(self, simulation): raise boom
        def simulation_finished(self, simulation): raise boom
        def refresh(self): raise boom
        def close(self): pass

    mgr._display = ExplodingDisplay()
    third = mgr.submit(__file__, config)
    queue.on_line(line(kind="QUEUE", event="ACCEPTED", timestamp="t", runID="3"))
    assert third.is_accepted, "the fold must still apply despite a display error"
    try:
        mgr.wait(timeout=1.0)
    except RuntimeError as error:
        assert error is boom
        print("ok: display errors surface on the caller's thread")
    else:
        raise AssertionError("display error was swallowed")

    # --- premature EOF abandons outstanding runs ----------------------
    mgr2 = SimulationManager(max_concurrent=1, refresh_interval=0)
    queue2 = fakes[-1]
    orphan = mgr2.submit(__file__, config)
    queue2.on_eof()
    assert orphan.wait(timeout=1.0) is True, "EOF must release waiters"
    assert not orphan.is_finished, "an abandoned run must not look finished"
    try:
        mgr2.wait(timeout=1.0)
    except RuntimeError as error:
        assert "closed before" in str(error), error
        print("ok: premature EOF abandons runs and faults the manager")
    else:
        raise AssertionError("premature EOF did not fault")

    # --- deliberate shutdown is not a fault ---------------------------
    mgr3 = SimulationManager(max_concurrent=1, refresh_interval=0)
    queue3 = fakes[-1]
    doomed = mgr3.submit(__file__, config)
    mgr3.shutdown()
    assert queue3.killed == 1
    assert doomed.wait(timeout=1.0) is True
    assert mgr3.wait(timeout=1.0) is True, "shutdown must not record a fault"
    print("ok: deliberate shutdown abandons runs without faulting")

    print("\nALL SMOKE CHECKS PASSED")


if __name__ == "__main__":
    main()
