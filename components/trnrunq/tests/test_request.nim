import std/[json, unittest]

import ../src/request


suite "queue request parsing":
  test "parses a complete request":
    let request = parseRequest($(%*{
      "runID": "run-1",
      "deckFile": "model.dck",
      "runnerPath": "trnrun.exe",
      "runnerArgs": ["--watchTmp:true", "--clean:true"],
    }))

    check request.runID == "run-1"
    check request.deckFile == "model.dck"
    check request.runnerPath == "trnrun.exe"
    check request.runnerArgs == @["--watchTmp:true", "--clean:true"]

  test "defaults runner arguments to empty":
    let request = parseRequest($(%*{
      "runID": "run-1",
      "deckFile": "model.dck",
      "runnerPath": "trnrun.exe",
    }))

    check request.runnerArgs.len == 0

  test "rejects malformed JSON and non-object values":
    expect JsonParsingError:
      discard parseRequest("{not JSON}")
    expect ValueError:
      discard parseRequest("[]")

  test "requires string request fields and a non-empty run identifier":
    for line in [
      "{}",
      $(%*{"runID": 1, "deckFile": "model.dck", "runnerPath": "trnrun.exe"}),
      $(%*{"runID": "run-1", "deckFile": 1, "runnerPath": "trnrun.exe"}),
      $(%*{"runID": "run-1", "deckFile": "model.dck", "runnerPath": 1}),
      $(%*{"runID": "", "deckFile": "model.dck", "runnerPath": "trnrun.exe"}),
    ]:
      expect ValueError:
        discard parseRequest(line)

  test "requires runner arguments to be strings":
    expect ValueError:
      discard parseRequest($(%*{
        "runID": "run-1",
        "deckFile": "model.dck",
        "runnerPath": "trnrun.exe",
        "runnerArgs": "--watchTmp:true",
      }))
    expect ValueError:
      discard parseRequest($(%*{
        "runID": "run-1",
        "deckFile": "model.dck",
        "runnerPath": "trnrun.exe",
        "runnerArgs": ["--watchTmp:true", 1],
      }))
