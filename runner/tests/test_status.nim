import std/[times, unittest]

import ../src/[events, status]


proc fixedTimestamp(): DateTime =
  dateTime(2026, mJun, 19, 19, 37, 13, 0, utc())


suite "simulation status outcomes":
  test "maps every result to its terminal wire status":
    let cases = [
      (outcome: simDone, expected: statusDone),
      (outcome: simCancelled, expected: statusCancelled),
      (outcome: simFatal, expected: statusError),
      (outcome: simTimeout, expected: statusTimeout),
      (outcome: simStalled, expected: statusStalled),
    ]

    for testCase in cases:
      checkpoint("outcome: " & $testCase.outcome)
      check testCase.outcome.status() == testCase.expected

  test "maps every result to its process exit code":
    let cases = [
      (outcome: simDone, expected: 0),
      (outcome: simCancelled, expected: 130),
      (outcome: simFatal, expected: 1),
      (outcome: simTimeout, expected: 124),
      (outcome: simStalled, expected: 125),
    ]

    for testCase in cases:
      checkpoint("outcome: " & $testCase.outcome)
      check testCase.outcome.exitCode() == testCase.expected

  test "creates a status event with an explicit timestamp":
    let event = statusEvent(statusRunning, fixedTimestamp())

    check event.kind == eventStatus
    check event.statusData == StatusEvent(
      timestamp: fixedTimestamp(),
      status: statusRunning,
    )

  test "timestamps a status event when no timestamp is supplied":
    let before = now().toTime()
    let event = statusEvent(statusPending)
    let after = now().toTime()
    let eventTime = event.statusData.timestamp.toTime()

    check event.kind == eventStatus
    check event.statusData.status == statusPending
    check eventTime >= before
    check eventTime <= after
