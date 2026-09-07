import std/[os, strutils, unittest]

import ../src/validate


proc runTests() =
  let
    testDirectory = getTempDir() /
      ("trnrunq_validate_tests_" & $getCurrentProcessId())
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  try:
    suite "runner path resolution":
      test "accepts absolute and executable-relative paths":
        let executableName = executable.extractFilename()

        check validateTrnrun(executable) == executable.normalizedPath()
        check validateTrnrun(executableName) ==
          (getAppDir() / executableName).normalizedPath()

      test "rejects missing paths":
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
