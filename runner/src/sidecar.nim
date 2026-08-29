## Manages files generated alongside a TRNSYS deck.

import std/[os, strformat]


const SidecarExtensions = [
  ".tmp", # Temporary progress file
  ".log", # Simulation log containing notices, warnings, and fatal errors
  ".lst", # Simulation list file
  ".PTI", # Online Plotter file
]

proc removeSidecarFiles*(deckFile: string): bool =
  ## Deletes TRNSYS sidecar files, returning false if any cannot be removed.
  result = true
  for extension in SidecarExtensions:
    let sidecarPath = deckFile.changeFileExt(extension)
    if not tryRemoveFile(sidecarPath):
      result = false
      stderr.writeLine(fmt"Warning: Could not delete {sidecarPath} (likely in use).")
