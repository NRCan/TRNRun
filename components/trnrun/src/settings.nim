## Defines TRNRun execution settings and defaults.
##
## Covers TRNSYS launch detection, runtime monitoring, cleanup, and event output,
## and converts settings into the `SETTING` event emitted at the start of each run.

import std/times
import ./events

type
  TrnexeGuiVisibility* = enum
    ## TrnEXE window mode; minimized modes launch visible, then minimize through Win32.
    guiKeepOpen = "keepOpen" # Visible; window stays open after the run.
    guiAutoClose = "autoClose" # Visible; window closes when the run finishes.
    guiMinimized = "minimized" # Minimized; window stays open after the run.
    guiMinimizedAuto = "minimizedAuto" # Minimized; closes after the run.
    guiHidden = "hidden" # No window at all.

  RunnerSettings* = object
    ## Settings controlling TRNSYS launch detection and runtime monitoring.
    trnexePath*: string
    guiVisibility*: TrnexeGuiVisibility
    waitForGui*: bool
    waitForLst*: bool
    waitForTmp*: bool
    detectTimeoutMs*: int
    extraDelayMs*: int
    watchLog*: bool
    watchTmp*: bool
    watchTimeoutMs*: int
    stallTimeoutMs*: int
    pollMs*: int
    cleanOnSuccess*: bool
    killOnTimeout*: bool
    killOnStall*: bool
    severity*: LogSeverity
    writeEvents*: bool

const DefaultRunnerSettings* = RunnerSettings(
  trnexePath: r"C:\TRNSYS18\Exe\TrnEXE64.exe",
  guiVisibility: guiHidden,
  waitForGui: true,
  waitForLst: true,
  waitForTmp: false,
  detectTimeoutMs: 300_000,
  extraDelayMs: 0,
  watchLog: true,
  watchTmp: false,
  watchTimeoutMs: 0,
  stallTimeoutMs: 0,
  pollMs: 100,
  cleanOnSuccess: false,
  killOnTimeout: false,
  killOnStall: false,
  severity: Notice,
  writeEvents: false,
)
  ## Default settings for TRNSYS simulation runs.

func normalized*(settings: RunnerSettings): RunnerSettings =
  ## Returns the effective settings used by readiness and runtime monitoring.
  result = settings
  result.detectTimeoutMs = max(0, result.detectTimeoutMs)
  result.extraDelayMs = max(0, result.extraDelayMs)
  result.pollMs = max(1, result.pollMs)
  result.watchTimeoutMs = max(0, result.watchTimeoutMs)
  result.stallTimeoutMs = max(0, result.stallTimeoutMs)

  if result.watchTimeoutMs > 0 and result.watchTimeoutMs < result.pollMs:
    result.watchTimeoutMs = result.pollMs
  if result.stallTimeoutMs > 0 and result.stallTimeoutMs < result.pollMs:
    result.stallTimeoutMs = result.pollMs

func flag*(visibility: TrnexeGuiVisibility): string =
  ## Returns the TrnEXE command-line switch for `visibility`, or "" for none.
  case visibility
  of guiKeepOpen, guiMinimized: ""
  of guiAutoClose, guiMinimizedAuto: "/n"
  of guiHidden: "/h"

func wantsMinimize*(visibility: TrnexeGuiVisibility): bool =
  ## Returns true if the mode needs post-launch Win32 minimization.
  visibility in {guiMinimized, guiMinimizedAuto}

proc settingEvent*(
    settings: RunnerSettings,
    trnexePath: string,
    timestamp: DateTime = now(),
): SimulationEvent =
  ## Converts settings to wire values using the resolved executable path.
  SimulationEvent(
    kind: eventSetting,
    settingData: SettingEvent(
      timestamp: timestamp,
      trnexePath: trnexePath,
      guiVisibility: $settings.guiVisibility,
      waitForGui: settings.waitForGui,
      waitForLst: settings.waitForLst,
      waitForTmp: settings.waitForTmp,
      detectTimeoutMs: settings.detectTimeoutMs,
      extraDelayMs: settings.extraDelayMs,
      watchLog: settings.watchLog,
      watchTmp: settings.watchTmp,
      watchTimeoutMs: settings.watchTimeoutMs,
      stallTimeoutMs: settings.stallTimeoutMs,
      pollMs: settings.pollMs,
      cleanOnSuccess: settings.cleanOnSuccess,
      killOnTimeout: settings.killOnTimeout,
      killOnStall: settings.killOnStall,
      severity: settings.severity,
      writeEvents: settings.writeEvents,
    ),
  )
