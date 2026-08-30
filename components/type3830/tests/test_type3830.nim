import std/[os, osproc, strutils, times, unittest]

const
  Trnsys17Exe = r"C:\Trnsys17\Exe\TrnEXE.exe"
  Trnsys18Exe = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  ExpectedTmpRecord = "10000.000000,0.000000,10000.000000,1.000000"

let
  testsDir = currentSourcePath().parentDir
  dckDir = testsDir / "dck"
  runnerPath = (testsDir / ".." / ".." / "runner" / "build" / "trnrun.exe").normalizedPath()
  runSpecs = [
    (name: "TRNSYS 17", deck: dckDir / "type3830-trnsys17.dck", trnexe: Trnsys17Exe),
    (name: "TRNSYS 18", deck: dckDir / "type3830-trnsys18.dck", trnexe: Trnsys18Exe),
  ]

type IntegrationRun = object
  name: string
  exitCode: int
  durationSeconds: float
  tmpGenerated: bool
  failure: string

proc passed(run: IntegrationRun): bool = run.failure.len == 0

proc fail(run: var IntegrationRun; message: string) =
  if run.failure.len > 0:
    run.failure.add("; ")
  run.failure.add(message)

proc runDeck(spec: tuple[name, deck, trnexe: string]): IntegrationRun =
  result = IntegrationRun(name: spec.name, exitCode: -1)
  let tmpPath = spec.deck.changeFileExt("tmp")

  for requirement in [
    (name: "Runner", path: runnerPath),
    (name: "TRNSYS executable", path: spec.trnexe),
    (name: "Deck", path: spec.deck),
  ]:
    if not fileExists(requirement.path):
      result.fail(requirement.name & " not found: " & requirement.path)
      return

  try:
    if fileExists(tmpPath):
      removeFile(tmpPath)
  except CatchableError:
    result.fail("Unable to remove stale TMP file: " & getCurrentExceptionMsg())
    return

  let startedAt = epochTime()
  try:
    let process = startProcess(
      runnerPath,
      args = @[
        "--deckFile=" & spec.deck,
        "--trnexePath=" & spec.trnexe,
        "--guiVisibility=hidden",
        "--waitForTmp=true",
        "--watchTmp=true",
        "--pollMs=1",
        "--clean=false",
      ],
      options = {poParentStreams},
    )
    try:
      result.exitCode = process.waitForExit()
    finally:
      process.close()
  except CatchableError:
    result.fail("Runner failed: " & getCurrentExceptionMsg())

  result.durationSeconds = epochTime() - startedAt
  result.tmpGenerated = fileExists(tmpPath)

  if result.failure.len == 0 and result.exitCode != 0:
    result.fail("Runner exited with code " & $result.exitCode)
  if not result.tmpGenerated:
    result.fail("TMP file was not generated: " & tmpPath)
  else:
    try:
      let record = readFile(tmpPath).strip()
      if record != ExpectedTmpRecord:
        result.fail(
          "Unexpected TMP record: expected '" & ExpectedTmpRecord &
            "', got '" & record & "'"
        )
    except CatchableError:
      result.fail("Unable to read TMP file: " & getCurrentExceptionMsg())

proc reportSummary(runs: openArray[IntegrationRun]) =
  var passedCount = 0

  echo "\nType3830 integration test summary"
  echo repeat("-", 66)
  echo alignLeft("Version", 14), alignLeft("Result", 10), alignLeft("Exit code", 12), alignLeft("TMP file", 12), "Duration"
  echo repeat("-", 66)

  for run in runs:
    if run.passed:
      inc passedCount
    echo alignLeft(run.name, 14),
      alignLeft(if run.passed: "PASS" else: "FAIL", 10),
      alignLeft(if run.exitCode >= 0: $run.exitCode else: "N/A", 12),
      alignLeft(if run.tmpGenerated: "YES" else: "NO", 12),
      formatFloat(run.durationSeconds, ffDecimal, 2), " s"

  echo repeat("-", 66)
  echo passedCount, "/", runs.len, " passed; ", runs.len - passedCount, " failed"
  for run in runs:
    if not run.passed:
      echo "  - ", run.name, ": ", run.failure

var runs: seq[IntegrationRun]

suite "Type3830 integration":
  for spec in runSpecs:
    test spec.name & " deck generates the expected final TMP record":
      let run = runDeck(spec)
      runs.add(run)
      if not run.passed:
        checkpoint run.failure
      check run.passed

reportSummary(runs)
