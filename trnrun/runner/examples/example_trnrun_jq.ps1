trnrun deck.dck --watchTmp:true |
  jq -r '
    select(.kind == "PROGRESS") |
    (.percent * 30 | floor) as $filled |
    "[" + ("#" * $filled) + ("-" * (30-$filled)) + "] " +
    ((.percent * 100) | floor | tostring) + "% ETA " +
    ((.eta / 1000) | round | tostring) + "s"
  ' |
  ForEach-Object {
      Write-Host "`r$(' ' * 60)`r$_" -NoNewline
  }