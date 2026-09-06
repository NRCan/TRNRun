import std/[json, times, unittest]

import ../src/status


suite "queue status formatting":
  test "formats a runner-compatible terminal error event":
    let
      runId = "failed-run"
      message = "the runner could not start"
      event = parseJson(errorLine(runId, message))

    check event.kind == JObject
    check event["kind"].getStr() == "STATUS"
    check event["status"].getStr() == "ERROR"
    check event["message"].getStr() == message
    check event["seq"].getInt() == 1
    check event["runId"].getStr() == runId
    check event["timestamp"].getStr().len == 19
    discard event["timestamp"].getStr().parse("yyyy-MM-dd'T'HH:mm:ss")
