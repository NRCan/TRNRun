import std/[os, strutils, unittest]

import ../src/validate


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc runTests() =
  let testDirectory = getTempDir() / "trnrun_validate_tests"
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

    test "rejects missing and unsupported deck files":
      let
        missingDeck = testDirectory / "missing.dck"
        unsupportedDeck = createDeck(testDirectory, "unsupported.txt")
      var
        missingRaised = false
        unsupportedRaised = false

      try:
        discard validateDeck(missingDeck)
      except IOError as error:
        missingRaised = error.msg.contains("Deck file not found:")

      try:
        discard validateDeck(unsupportedDeck)
      except ValueError as error:
        unsupportedRaised = error.msg.contains("Expected .dck or .trd")

      check missingRaised
      check unsupportedRaised

    test "validates the TrnEXE path":
      let missingTrnexe = testDirectory / "missing-TrnEXE64.exe"
      check validateTrnexe(getAppFilename()) ==
        getAppFilename().absolutePath().normalizedPath()

      var missingRaised = false
      try:
        discard validateTrnexe(missingTrnexe)
      except IOError as error:
        missingRaised = error.msg.contains("TRNEXE not found:")
      check missingRaised

runTests()
