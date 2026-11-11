# Linux support through Wine: findings

Status as of 2026-11-10. Tested on Windows 11 with WSL 2 (Ubuntu 24.04), TRNSYS 18, TRNRun 0.9.2.

## Approach

The Python library runs `wine trnrund.exe`. trnrund, trnrun and TrnEXE then all run inside
one Wine prefix. The Nim components stay Windows-only and are not ported.

Porting only trnrund to native Linux was rejected: its Win32 Job Object, which kills TRNRun
and TRNSYS when the daemon dies, can't hold Wine processes, and paths would need converting
between trnrund and TRNRun.

Only Python sees Linux paths, and it converts them on the way to and from trnrund:

- `/home/me/deck.dck` ↔ `Z:\home\me\deck.dck` (Wine maps `Z:` to `/`)
- `C:\TRNSYS18\…` ↔ `$WINEPREFIX/dosdevices/c:/TRNSYS18/…`

## What works under Wine

`scripts/wine_smoke.py` checks the whole stack. It needs only the Python standard library and
runs on the Linux host. All checks pass on Wine 9.0 (Ubuntu) and Wine 11.0 (WineHQ):

| Check | Result |
|---|---|
| TRNSYS runs and accepts its licence | ✅ |
| trnrun events, PROGRESS from Type3830 | ✅ |
| Window detection and minimizing (`EnumWindows`, `ShowWindow`) | ✅ with a display |
| trnrund `ready` / `add` / polling | ✅ |
| 3 concurrent runs (`Global\TRNRun_LaunchMutex`) | ✅ |
| Closing trnrund's stdin kills TRNRun and TrnEXE | ✅ |
| `SIGKILL` on trnrund kills TRNRun and TrnEXE (Job Object kill-on-close) | ✅ |
| `keepAwake` | Runs, but has no effect on the Linux host |

No Nim changes were needed.

## Findings

### `WINEDEBUG=-all` is mandatory

trnrund merges TRNRun's stderr into its stdout (`trnrund/src/trnrun.nim`, `poStdErrToStdOut`),
and TRNSYS's stderr is inherited along the way. Wine's own messages then end up in the JSON
event stream: 1 line per run on Wine 9, 27 on Wine 11 (`fixme:` stubs). The library always sets
`WINEDEBUG=-all`.

### Wine needs a display, even for hidden windows

Without `DISPLAY`, TrnEXE quits after about 2 s (`nodrv_CreateWindow`), even with `/h`. trnrun
then reports **DONE**: with `watchTmp` on, a run that never wrote a `.tmp` snapshot falls
through to `simDone` (`trnrun/src/monitor.nim:417-422`). The library therefore starts a
private Xvfb when `DISPLAY` is unset, and stops it on `close()`.

Under WSLg, `/tmp/.X11-unix` isn't writable by Xvfb, so `Xvfb -displayfd` rejects every display
number. Starting it with `-nolisten unix` (abstract socket only) works there and on normal Linux.

### `python37.dll` error from Type169

Wine logs `Library python37.dll … not found` for `C:\TRNSYS18\UserLib\ReleaseDLLs\Type169.dll`
(CallPython). The same DLL fails to load silently on Windows too when Python 3.7 isn't
installed, and no deck in this repo uses Type 169. It can be ignored. A deck that uses Type 169
needs Python 3.7 inside the prefix, just as it needs it on Windows.

### Performance

Slow deck (`decks/slow_wo_plot_w_tracking.dck`, 100,000 steps), timed with `trnrun.exe`, deck
in the Linux filesystem (`~`):

| | Windows | Wine 11.0 (WineHQ) | Wine 9.0 (Ubuntu) |
|---|---|---|---|
| 100,000 steps (`STEP=0.1`) | 6.2 s | 8.4 s | 15.4 s |
| 10,000 steps (`STEP=1`) | 0.8 s | 1.8 s | 3.1 s |
| Per time step | ~60 µs | ~73 µs (+22 %) | ~137 µs (+130 %) |
| Fixed cost per run | ~0.2 s | ~1.1 s | ~1.7 s |

- **Use WineHQ's Wine 11 or later**, not Ubuntu's `wine` package: the per-step overhead drops
  from +130 % to +22 %.
- **Keep decks out of `/mnt/c` on WSL.** The same run took 20.0 s from `/mnt/c` instead of
  15.4 s from `~` (Wine 9).
- The overhead is per time step, not on the arithmetic. TRNDll64 links the Intel Fortran and
  math runtimes statically, so calculation runs at native speed. It isn't the display either
  (Xvfb is no faster than WSLg), nor Type3830 (tracking makes no difference). The likely cause
  is TRNSYS's per-step window and message handling going through wineserver, which newer Wine
  versions largely avoid. This is an inference, not measured directly.
- Decks that compute more per step have the same absolute overhead, so a smaller relative one.
  This test deck is close to the worst case.
- Startup costs add up across runs. trnrun holds the launch mutex from starting TrnEXE until it
  is ready (`trnrun/src/simulate.nim:51-71`), so launches run one at a time and each run pays the
  ~1 s of Wine startup in turn. With `example_manager.py` (10 runs, 5 workers), Windows took
  about 7 s and Wine 11 about 11 s from `/mnt/c`.

## Setup on WSL (Ubuntu 24.04)

```bash
# WineHQ Wine, installed beside Ubuntu's in /opt/wine-stable
sudo mkdir -pm755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
sudo wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources
sudo apt update
sudo apt install --install-recommends wine-stable xvfb rsync

# Prefix with TRNSYS copied from Windows (includes Type3830 if installed there)
export WINEPREFIX=~/.wine-stable
WINEDLLOVERRIDES="mscoree,mshtml=" /opt/wine-stable/bin/wine wineboot -u
cp -r /mnt/c/TRNSYS18 ~/.wine-stable/drive_c/
```

Use a separate prefix for each Wine version: a newer Wine permanently upgrades any prefix it
opens. `winehq-stable` instead of `wine-stable` puts Wine 11 at `/usr/bin/wine`, but conflicts
with Ubuntu's `wine` package.

Run the smoke test, and the example from the Linux filesystem:

```bash
REPO=/mnt/c/Users/<you>/…/TRNRun
cd "$REPO"
TRNRUN_WINE=/opt/wine-stable/bin/wine WINEPREFIX=~/.wine-stable python3 scripts/wine_smoke.py

mkdir -p ~/TRNRun/libraries
rsync -a --exclude .venv --exclude runs --exclude __pycache__ "$REPO/libraries/python" ~/TRNRun/libraries/
rsync -a "$REPO/decks" ~/TRNRun/
cd ~/TRNRun
TRNRUN_WINE=/opt/wine-stable/bin/wine WINEPREFIX=~/.wine-stable PYTHONPATH=libraries/python \
  python3 libraries/python/examples/example_manager.py
```

Other useful smoke test options: `--only <checks>`, `--write-events` (writes a `.jsonl` next
to each deck), and `env -u DISPLAY -u WAYLAND_DISPLAY` to test without a display.

## Python library changes (done, uncommitted)

- `trnrun/_platform.py`, the only module where Windows and Linux differ:
  - converts paths (`to_trnrund`, `from_trnrund`)
  - starts a bundled executable on either platform (`launch`): without a console window on
    Windows; elsewhere it finds Wine (`TRNRUN_WINE`, default `wine`), sets `WINEDEBUG=-all`,
    and starts a private Xvfb when there's no X display
- `trnrun/daemon.py`:
  - starts trnrund with `launch`, with no platform branch of its own
  - converts the deck path, and stops Xvfb on `close()`
  - raises `FileNotFoundError` for a missing trnrund, Wine or Xvfb
- `trnrun/settings.py`: `trnexe_path` can be a Linux path or a path inside the prefix
  (`C:\TRNSYS18\…`). Python checks that a Linux path exists. A path inside the prefix is
  left to TRNRun, which fails the simulation if it is missing: Wine ignores case, so a
  check from Python would refuse `C:\trnsys18\…` when the folder on disk is `TRNSYS18`.
- `trnrun/simulation.py`: `deck_file` comes back as a Linux path.
- `tests/test_platform.py`: path conversion and the Wine environment. These tests don't need Wine.

Checked end to end in WSL with a display and headless (private Xvfb). pytest runs there
through the CI reproduction below.

## Open items

- [ ] Warn when `keep_awake=True` off Windows, and when Wine is older than version 10.
- [x] Linux wheel from the same `.exe` files. `TRNRUN_WHEEL_PLATFORM=manylinux_2_17_x86_64`
      selects its tag in `hatch_build.py`. `just python-dist` builds both wheels on Windows,
      since the build hook runs the executables. Classifier `Operating System :: POSIX :: Linux`.
- [x] CI job `linux` in `build.yml`: Ubuntu 24.04, WineHQ `wine-stable`, no display (each
      daemon starts its own Xvfb). It runs pytest with the executables from the Linux wheel,
      then installs that wheel and starts trnrund from it. The fake TRNRun is the Windows
      embeddable Python unzipped beside the prefix (`TRNRUN_TEST_PYTHON`), so the tests stay
      unchanged. Reproduced locally in WSL (46 passed, 3 skipped), but **not yet run on GitHub**.
- [ ] Linux section in the root and Python READMEs: WineHQ 11+, TRNSYS in the prefix,
      `WINEPREFIX`/`TRNRUN_WINE`, automatic Xvfb, performance, limitations (`keep_awake`,
      Type 169, `/mnt/c`).
- [ ] Try `wait_for_gui=False` to hold the launch mutex for less time. First check that
      concurrent launches stay safe (`wine_smoke.py --only daemon-concurrent --workers 5`
      with `waitForGui` false).
- [ ] Measure on native Linux. Kernel 6.14+ has `ntsync` (`/dev/ntsync`), which Wine 11 is
      thought to use for faster synchronization. WSL's kernel doesn't have it. Unverified.
- [ ] Separate from Linux: trnrun reports DONE when TRNSYS exits without ever writing a `.tmp`
      snapshot (`monitor.nim:417-422`). That also hides a TRNSYS crash on Windows. A fix could
      treat "no snapshot" as an error when the deck contains `TYPE 3830`.
- [ ] Same Wine launch and path conversion for the .NET and MATLAB libraries.
