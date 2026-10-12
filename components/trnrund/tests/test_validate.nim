import std/[os, strutils, unittest]

import ../src/validate


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc raisesValueError(validation: proc(), expected: string): bool =
  ## Whether `validation` raises a `ValueError` whose message holds `expected`.
  result = false
  try:
    validation()
  except ValueError as error:
    result = error.msg.contains(expected)

proc runTests() =
  let testDirectory = getTempDir() / "trnrund_validate_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "input validation":
    test "accepts existing DCK and TRD files case-insensitively":
      let
        dckFile = createDeck(testDirectory, "validation.DCK")
        trdFile = createDeck(testDirectory, "validation.TRd")

      check validateDeck(dckFile) == dckFile.absolutePath().normalizedPath()
      check validateDeck(trdFile) == trdFile.absolutePath().normalizedPath()

    test "resolves a relative deck from the working directory":
      let
        deckFile = createDeck(testDirectory, "relative.dck")
        previousDirectory = getCurrentDir()
      setCurrentDir(testDirectory)
      defer: setCurrentDir(previousDirectory)

      check validateDeck("relative.dck") == deckFile.absolutePath().normalizedPath()

    test "rejects missing and unsupported deck files with ValueError":
      let
        missingDeck = testDirectory / "missing.dck"
        unsupportedDeck = createDeck(testDirectory, "unsupported.txt")

      check raisesValueError(
        proc() = discard validateDeck(missingDeck), "Deck file not found:"
      )
      check raisesValueError(
        proc() = discard validateDeck(unsupportedDeck), "Expected .dck or .trd"
      )

    test "validates the TRNRun path":
      check validateFile(getAppFilename(), "TRNRun") ==
        getAppFilename().absolutePath().normalizedPath()

      let missingTrnrun = testDirectory / "missing-trnrun.exe"
      check raisesValueError(
        proc() = discard validateFile(missingTrnrun, "TRNRun"), "TRNRun not found:"
      )

    test "accepts the TRNRun options clients set":
      validateTrnrunArgs([])
      validateTrnrunArgs([
        "--trnexePath:C:/Program Files/TRNSYS/TrnEXE64.exe", "--guiVisibility:hidden",
        "--watchTmp:true", "--pollMs=50", "--severity:Warning", "--writeEvents:false",
      ])

    test "rejects TRNRun arguments TRNRun or the daemon would refuse":
      let cases = [
        (args: @["--watchTMP:true"], expected: "Unknown option in trnrunArgs: 'watchTMP'"),
        (args: @["-x"], expected: "Unknown option in trnrunArgs: 'x'"),
        (args: @["--pollMs:fast"], expected: "Invalid value for 'pollMs' in trnrunArgs:"),
        (args: @["--watchTmp:yes please"], expected: "Invalid value for 'watchTmp' in trnrunArgs:"),
        (args: @["--guiVisibility:loud"], expected: "Invalid value for 'guiVisibility' in trnrunArgs:"),
        (args: @["--deckFile:other.dck"], expected: "Option not allowed in trnrunArgs: 'deckFile'"),
        (args: @["--deckFile=other.dck"], expected: "Option not allowed in trnrunArgs: 'deckFile'"),
        (args: @["--runId:other"], expected: "Option not allowed in trnrunArgs: 'runId'"),
        (args: @["--help"], expected: "Option not allowed in trnrunArgs: 'help'"),
        (args: @["-v"], expected: "Option not allowed in trnrunArgs: 'v'"),
        (args: @["other.dck"], expected: "Unexpected argument in trnrunArgs: 'other.dck'"),
      ]
      for testCase in cases:
        checkpoint($testCase.args)
        let args = testCase.args
        check raisesValueError(proc() = validateTrnrunArgs(args), testCase.expected)

runTests()
