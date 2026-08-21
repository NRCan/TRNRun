import std/[json, times, unittest]
import ../src/events
import ../src/settings

suite "SETTING events":
  test "serialize every runner setting":
    var settings = DefaultRunnerSettings
    settings.detectTimeoutMs = 1_000
    settings.extraDelayMs = 250
    settings.watchTimeoutMs = 2_000
    settings.stallTimeoutMs = 3_000
    settings.killOnTimeout = true
    settings.severity = Warning
    settings.writeEvents = true

    let timestamp = dateTime(2026, mJun, 19, 19, 37, 13)
    let event = settingEvent(settings, r"C:\TRNSYS18\Exe\TrnEXE64.exe", timestamp)

    let node = event.toJson()
    check node.len == 19
    check node["kind"].getStr() == "SETTING"
    check node["timestamp"].getStr() == "2026-06-19T19:37:13"
    check node["trnexePath"].getStr() == r"C:\TRNSYS18\Exe\TrnEXE64.exe"
    check node["guiVisibility"].getStr() == "hidden"
    check node["waitForGui"].getBool()
    check not node["waitForTmp"].getBool()
    check node["detectTimeoutMs"].getInt() == 1_000
    check node["pollMs"].getInt() == 100
    check node["killOnTimeout"].getBool()
    check node["severity"].getStr() == "Warning"
    check node["writeEvents"].getBool()

  test "construct lifecycle status events":
    let node = statusEvent(statusRunning).toJson()

    check node["kind"].getStr() == "STATUS"
    check node["status"].getStr() == "RUNNING"
