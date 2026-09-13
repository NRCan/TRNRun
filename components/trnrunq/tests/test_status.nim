import std/[json, options, times, unittest]

import ../src/status


suite "queue status formatting":
  test "formats accepted events":
    let event = parseJson(acceptedLine("accepted-run"))

    check event.kind == JObject
    check event["kind"].getStr() == "QUEUE"
    check event["event"].getStr() == "ACCEPTED"
    check event["runID"].getStr() == "accepted-run"
    check event["timestamp"].getStr().len == 19
    discard event["timestamp"].getStr().parse("yyyy-MM-dd'T'HH:mm:ss")


  test "formats a runner-compatible terminal error event":
    let
      runID = "failed-run"
      message = "the runner could not start"
      event = parseJson(errorLine(runID, message))

    check event.kind == JObject
    check event["kind"].getStr() == "STATUS"
    check event["status"].getStr() == "ERROR"
    check event["message"].getStr() == message
    check event["seq"].getInt() == 1
    check event["runID"].getStr() == runID
    check event["timestamp"].getStr().len == 19
    discard event["timestamp"].getStr().parse("yyyy-MM-dd'T'HH:mm:ss")


  test "formats completed events with present and absent exit codes":
    let
      exited = parseJson(completedLine("exited", some(2)))
      notLaunched = parseJson(completedLine("not-launched", none(int)))

    check exited["kind"].getStr() == "QUEUE"
    check exited["event"].getStr() == "COMPLETED"
    check exited["runID"].getStr() == "exited"
    check exited["exitCode"].kind == JInt
    check exited["exitCode"].getInt() == 2
    check exited["timestamp"].getStr().len == 19
    check exited.len == 5

    check notLaunched["kind"].getStr() == "QUEUE"
    check notLaunched["event"].getStr() == "COMPLETED"
    check notLaunched["runID"].getStr() == "not-launched"
    check notLaunched["exitCode"].kind == JNull
    check notLaunched.len == 5
