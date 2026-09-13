import std/[os, unittest]

import ../src/sidecar


proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)
  elif dirExists(path):
    removeDir(path)

proc runTests() =
  let testDirectory = getTempDir() / "trnrun_sidecar_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "sidecar cleanup":
    test "removes every supported sidecar and preserves the deck":
      let deckFile = testDirectory / "cleanup.dck"
      writeFile(deckFile, "deck")
      for extension in ["tmp", "log", "lst", "PTI"]:
        writeFile(deckFile.changeFileExt(extension), "generated")

      check removeSidecarFiles(deckFile)
      check fileExists(deckFile)
      for extension in ["tmp", "log", "lst", "PTI"]:
        check not fileExists(deckFile.changeFileExt(extension))

    test "succeeds when no sidecars exist":
      let deckFile = testDirectory / "absent.dck"
      writeFile(deckFile, "deck")

      check removeSidecarFiles(deckFile)
      check fileExists(deckFile)

    test "reports a failed deletion and continues removing other sidecars":
      let
        deckFile = testDirectory / "failure.dck"
        blockedSidecar = deckFile.changeFileExt("tmp")
        removableSidecar = deckFile.changeFileExt("log")
      createDir(blockedSidecar)
      writeFile(removableSidecar, "generated")
      defer: removeIfExists(blockedSidecar)

      check not removeSidecarFiles(deckFile)
      check dirExists(blockedSidecar)
      check not fileExists(removableSidecar)

runTests()
