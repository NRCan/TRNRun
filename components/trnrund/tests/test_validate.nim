import std/[json, os, unittest]

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

  test "validateTrnrunOptions accepts any named string, boolean or number, leaving the rest to TRNRun":
    validateTrnrunOptions(newJObject())
    validateTrnrunOptions(%*{"guiVisibility": "min", "clean": true, "pollMs": 0, "detectTimeout": 5000.0, "bogus": "x"})

  test "validateTrnrunOptions rejects another kind of value":
    for value in [newJNull(), %*[1], %*{"a": 1}]:
      expect InputError:
        validateTrnrunOptions(%*{"pollMs": value})

  test "validateTrnrunOptions rejects a reserved or malformed name":
    # "deckFile:other.dck" would reach TRNRun as --deckFile:other.dck:true.
    for key in ["deckFile", "help", "h", "version", "v", "", "deckFile:other.dck", "deckFile=x", "-h", "a b"]:
      expect InputError:
        validateTrnrunOptions(%*{key: true})

removeDir(dir)
