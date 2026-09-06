# Python `trnrunq.exe` migration

The Python manager now delegates simulation queueing and concurrency to one bundled `trnrunq.exe` process.

## Implemented design

- [x] `SimulationManager` starts one `trnrunq.exe` process.
- [x] Queue concurrency is configured with `max_concurrent` and `max_pending`.
- [x] The manager writes one JSON request per line to queue stdin.
- [x] One background thread reads queue stdout.
- [x] Events are routed to simulations using `str(Simulation.id)` as `runId`.
- [x] Blank, non-JSON, invalid, and unknown-run output is ignored.
- [x] Every simulation completes when it receives a terminal `STATUS` event.
- [x] `Simulation` uses one `threading.Event` for waiting and completion state.
- [x] `DONE` is the only successful terminal status.
- [x] Python no longer owns worker threads, runner processes, child PIDs, or exit codes.
- [x] Cancellation is not currently exposed.
- [x] Closing the manager closes queue stdin and drains accepted work.
- [x] Both `trnrun.exe` and `trnrunq.exe` are included in Windows wheels.
- [x] Python-side Windows Job Object management was removed because the queue owns descendant cleanup.

## Remaining validation

- [ ] Run the Python unit tests in an environment with Python and development dependencies installed.
- [ ] Run the Windows end-to-end test with both bundled executables deployed.
- [ ] Build and inspect a wheel to confirm both executables are included.
