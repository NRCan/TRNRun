import std/[os, tempfiles, unittest]
import ../src/validate

suite "Daemon path validation":
  test "deck extensions are case-insensitive and paths are normalized":
    let directory = createTempDir("trnrund-decks-", "")
    try:
      for name in ["deck.dck", "deck.DCK", "deck.trd", "deck.TRd"]:
        let path = directory / name
        writeFile(path, "")
        check validateDeck(path) == path.absolutePath().normalizedPath()
        check validateDeck(directory / "unused" / ".." / name) ==
          path.absolutePath().normalizedPath()
    finally:
      removeDir(directory)

  test "missing, unsupported, and directory deck paths are rejected":
    let directory = createTempDir("trnrund-invalid-decks-", "")
    try:
      let unsupported = directory / "deck.txt"
      writeFile(unsupported, "")
      let deckDirectory = directory / "directory.dck"
      createDir(deckDirectory)
      for path in [directory / "missing.dck", unsupported, deckDirectory, ""]:
        expect ValueError:
          discard validateDeck(path)
    finally:
      removeDir(directory)

  test "TRNRun validation checks file existence, not executable contents":
    let directory = createTempDir("trnrund-runner-", "")
    try:
      let path = directory / "runner.exe"
      writeFile(path, "not an executable")
      check validateTrnrun(path) == path.absolutePath().normalizedPath()
      check validateTrnrun(directory / "unused" / ".." / "runner.exe") ==
        path.absolutePath().normalizedPath()
    finally:
      removeDir(directory)

  test "missing and directory TRNRun paths are rejected":
    let directory = createTempDir("trnrund-invalid-runner-", "")
    try:
      for path in [directory / "missing.exe", directory, ""]:
        expect ValueError:
          discard validateTrnrun(path)
    finally:
      removeDir(directory)

  test "relative deck and TRNRun paths resolve from the working directory":
    let directory = createTempDir("trnrund-relative-", "")
    try:
      let deck = directory / "deck.dck"
      let runner = directory / "runner.exe"
      writeFile(deck, "")
      writeFile(runner, "")
      check validateDeck(deck.relativePath(getCurrentDir())) ==
        deck.absolutePath().normalizedPath()
      check validateTrnrun(runner.relativePath(getCurrentDir())) ==
        runner.absolutePath().normalizedPath()
    finally:
      removeDir(directory)
