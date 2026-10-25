## Defines TRNRun execution settings defaults and helpers.
##
## Covers TRNSYS launch detection, runtime monitoring, cleanup, and event output,
## and converts settings into the `SETTING` event emitted at the start of each run.
## The `RunnerSettings` type itself lives in `events` and is re-exported here.

import std/times
import ./events

export TrnexeGuiVisibility, RunnerSettings

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
  severity: sevNotice,
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

proc settingEvent*(settings: RunnerSettings, timestamp: DateTime = now()): SimulationEvent =
  ## Wraps the effective settings, with `trnexePath` already resolved, as a `SETTING` event.
  SimulationEvent(
    kind: eventSetting,
    settingData: SettingEvent(timestamp: timestamp, settings: settings),
  )
