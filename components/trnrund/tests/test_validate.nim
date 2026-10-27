import std/[os, unittest]

import ../src/validate
import ./fake_trnrun
import ./junit

let dir = createDeckDir()

suite "validate":
  test "validateFile returns an existing file absolute and normalized":
    let file = createDeck(dir, "a.dck")
    check validateFile(dir / "sub" / ".." / "a.dck", "Deck file") == file

  test "validateFile rejects a missing file, naming it":
    expect InputError:
      discard validateFile(dir / "missing.exe", "TRNRun")
    try:
      discard validateFile(dir / "missing.exe", "TRNRun")
    except InputError as error:
      check error.msg == "TRNRun not found: '" & dir / "missing.exe" & "'"

  test "validateDeck accepts .dck and .trd in any case":
    for name in ["b.dck", "c.TRD"]:
      check validateDeck(createDeck(dir, name)) == dir / name

  test "validateDeck rejects another file type":
    expect InputError:
      discard validateDeck(createDeck(dir, "d.txt"))

  test "validateTrnrunArgs accepts TRNRun options":
    validateTrnrunArgs([])
    validateTrnrunArgs(["--guiVisibility:min", "--pollMs:50", "--clean:true", "--runId:x"])

  test "validateTrnrunArgs rejects what TRNRun or the daemon would not take":
    for args in [
      @["other.dck"],
      @["--deckFile:other.dck"],
      @["--help"],
      @["-v"],
      @["--bogus:1"],
      @["--pollMs:0"],
      @["--clean:maybe"],
    ]:
      expect InputError:
        validateTrnrunArgs(args)

removeDir(dir)
