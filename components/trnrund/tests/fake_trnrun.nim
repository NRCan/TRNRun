## Test child: emits protocol events and optionally waits for a release file.
import std/[os, times]

let deck = paramStr(1)
let mode = readFile(deck)
echo "ordinary diagnostic output"
echo "{\"kind\":\"STATUS\",\"status\":\"RUNNING\",\"message\":\"Started\"}"
echo "{\"kind\":\"PROGRESS\",\"time\":1,\"percent\":0.1,\"elapsedMs\":20,\"etaMs\":180}"
echo "{\"kind\":\"LOG\",\"severity\":\"Notice\",\"time\":1,\"message\":\"Started\"}"

if mode == "done-first":
  echo "{\"kind\":\"STATUS\",\"status\":\"DONE\",\"message\":\"Completed\"}"
stdout.flushFile()
writeFile(deck & ".ready", "")

if mode in ["hold", "done-first"]:
  let deadline = epochTime() + 5
  while not fileExists(deck & ".release"):
    if epochTime() > deadline:
      quit(1)
    sleep(5)

if mode != "no-status" and mode != "done-first":
  echo "{\"kind\":\"STATUS\",\"status\":\"DONE\",\"message\":\"Completed\"}"
stdout.flushFile()
