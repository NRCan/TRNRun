import std/[os, osproc, strutils, unittest]

import ../src/[settings, trnexe]


if paramCount() >= 1 and
    paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
  let deckFile = paramStr(1)
  writeFile(
    deckFile.changeFileExt("launch"),
    getCurrentDir() & "\n" & commandLineParams().join("\n"),
  )
  quit(QuitSuccess)

proc runLaunch(deckFile: string, visibility: TrnexeGuiVisibility): seq[string] =
  let process = launchTrnexe(deckFile, getAppFilename(), visibility)
  defer: process.close()

  check process.waitForExit() == QuitSuccess
  result = readFile(deckFile.changeFileExt("launch")).splitLines()

proc runTests() =
  let testDirectory = getTempDir() / "trnrun_trnexe_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "TrnEXE launch":
    test "uses the deck directory and passes each visibility switch":
      let cases = [
        (visibility: guiKeepOpen, switch: ""),
        (visibility: guiAutoClose, switch: "/n"),
        (visibility: guiMinimized, switch: ""),
        (visibility: guiMinimizedAuto, switch: "/n"),
        (visibility: guiHidden, switch: "/h"),
      ]

      for index, testCase in cases:
        checkpoint("visibility: " & $testCase.visibility)
        let deckFile = testDirectory / ("launch-" & $index & ".dck")
        writeFile(deckFile, "deck")

        let captured = runLaunch(deckFile, testCase.visibility)

        check captured[0] == testDirectory
        check captured[1] == deckFile
        if testCase.switch.len == 0:
          check captured.len == 2
        else:
          check captured.len == 3
          check captured[2] == testCase.switch

    test "wraps process creation failures":
      let
        deckFile = testDirectory / "failure.dck"
        missingExecutable = testDirectory / "missing-TrnEXE64.exe"
      writeFile(deckFile, "deck")

      var message = ""
      try:
        discard launchTrnexe(deckFile, missingExecutable, guiHidden)
      except TrnexeLaunchError as error:
        message = error.msg

      check message.startsWith("Failed to launch TRNSYS:")

runTests()
