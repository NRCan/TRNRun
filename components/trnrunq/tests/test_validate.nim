import std/[os, strutils, unittest]

import ../src/validate


proc createFile(directory, name: string): string =
  result = directory / name
  writeFile(result, "test file")

proc runTests() =
  let
    testDirectory = getTempDir() /
      ("trnrunq_validate_tests_" & $getCurrentProcessId())
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  try:
    suite "runner input validation":
      test "accepts existing deck files with supported extensions":
        let
          dckFile = createFile(testDirectory, "model.dck")
          trdFile = createFile(testDirectory, "model.TRD")

        check validateDeck(dckFile) == dckFile.absolutePath().normalizedPath()
        check validateDeck(trdFile) == trdFile.absolutePath().normalizedPath()

      test "rejects missing deck files":
        let missingDeck = testDirectory / "missing.dck"

        try:
          discard validateDeck(missingDeck)
          check false
        except IOError as error:
          check error.msg.contains("Deck file not found:")
          check error.msg.contains(missingDeck.normalizedPath())

      test "rejects unsupported deck extensions":
        let invalidDeck = createFile(testDirectory, "model.txt")

        try:
          discard validateDeck(invalidDeck)
          check false
        except ValueError as error:
          check error.msg.contains("Expected .dck or .trd")
          check error.msg.contains(invalidDeck)

      test "accepts absolute and executable-relative runner paths":
        let executableName = executable.extractFilename()

        check validateTrnrun(executable) == executable.normalizedPath()
        check validateTrnrun(executableName) ==
          (getAppDir() / executableName).normalizedPath()

      test "rejects missing runner paths":
        let missingRunner = testDirectory / "missing-trnrun.exe"

        try:
          discard validateTrnrun(missingRunner)
          check false
        except IOError as error:
          check error.msg.contains("TRNRun not found:")
          check error.msg.contains(missingRunner.normalizedPath())
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
