import std/[json, options, times, unittest]
import ../src/events

const TimestampText = "1970-01-01T00:00:00"

let timestamp = fromUnix(0).utc()

suite "simulation event serialization":
  test "uses explicit wire values":
    check $eventStatus == "STATUS"
    check $eventConfig == "CONFIG"
    check $eventProgress == "PROGRESS"
    check $eventLog == "LOG"
    check $Notice == "Notice"
    check $Warning == "Warning"
    check $Fatal == "Fatal"

  test "serializes a concrete event with the JSON operator":
    let event = StatusEvent(timestamp: timestamp, status: statusRunning)
    let value = %event

    check value["kind"].getStr() == "STATUS"
    check value["timestamp"].getStr() == TimestampText
    check value["status"].getStr() == "RUNNING"


  test "serializes every status value":
    let expected = [
      (statusPending, "PENDING"),
      (statusLaunching, "LAUNCHING"),
      (statusRunning, "RUNNING"),
      (statusDone, "DONE"),
      (statusCancelled, "CANCELLED"),
      (statusError, "ERROR"),
      (statusTimeout, "TIMEOUT"),
      (statusStalled, "STALLED"),
    ]

    for (status, statusText) in expected:
      let value = statusEvent(status, timestamp).toJson()
      check value["kind"].getStr() == "STATUS"
      check value["timestamp"].getStr() == TimestampText
      check value["status"].getStr() == statusText

  test "serializes simulation configuration":
    let value = configEvent(0.0, 8760.0, 0.25, timestamp).toJson()

    check value["kind"].getStr() == "CONFIG"
    check value["timestamp"].getStr() == TimestampText
    check value["start"].getFloat() == 0.0
    check value["stop"].getFloat() == 8760.0
    check value["step"].getFloat() == 0.25

  test "serializes progress using the established precision":
    let value = progressEvent(
      time = 12.3456,
      percent = 0.123456,
      elapsedMs = 1234.567,
      etaMs = 8765.432,
      timestamp = timestamp,
    ).toJson()

    check value["kind"].getStr() == "PROGRESS"
    check value["timestamp"].getStr() == TimestampText
    check value["time"].getFloat() == 12.35
    check value["percent"].getFloat() == 0.1235
    check value["elapsed"].getFloat() == 1234.57
    check value["eta"].getFloat() == 8765.43

  test "omits absent optional log fields":
    let value = logEvent(Notice, 10.0, timestamp = timestamp).toJson()

    check value["kind"].getStr() == "LOG"
    check value["timestamp"].getStr() == TimestampText
    check value["severity"].getStr() == "Notice"
    check value["time"].getFloat() == 10.0
    check not value.hasKey("unitID")
    check not value.hasKey("typeID")
    check not value.hasKey("messageCode")
    check not value.hasKey("message")
    check not value.hasKey("information")

  test "includes present optional log fields using canonical keys":
    let value = logEvent(
      severity = Warning,
      time = 20.0,
      unitId = some(5),
      typeId = some(139),
      messageCode = some(123),
      message = some("Warning message"),
      information = some("Additional information"),
      timestamp = timestamp,
    ).toJson()

    check value["severity"].getStr() == "Warning"
    check value["unitID"].getInt() == 5
    check value["typeID"].getInt() == 139
    check value["messageCode"].getInt() == 123
    check value["message"].getStr() == "Warning message"
    check value["information"].getStr() == "Additional information"
    check not value.hasKey("unitId")
    check not value.hasKey("typeId")

  test "produces compact single-line JSON":
    let line = statusEvent(statusRunning, timestamp).toJsonLine()
    let value = parseJson(line)

    check not line.contains('\n')
    check not line.contains('\r')
    check value["kind"].getStr() == "STATUS"
    check value["status"].getStr() == "RUNNING"
