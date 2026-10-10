switch("mm", "orc")
switch("threads", "on")
switch("errorMax", "3")
switch("styleCheck", "hint")
switch("experimental", "strictDefs")

when defined(windows):
  # db_connector 0.1.0 has no DLL-name define. Link its official bindings
  # directly to the built-in Windows 10+ DLL (supported by GCC and Zig).
  switch("dynlibOverride", "sqlite3")
  switch("passL", "\"" & getEnv("SystemRoot", "C:\\Windows") &
    "\\System32\\winsqlite3.dll\"")

switch("warningAsError", "ProveInit")
switch("warningAsError", "Deprecated")
switch("warningAsError", "UnusedImport")
switch("warningAsError", "CStringConv")
switch("warningAsError", "HoleEnumConv")

switch("hint", "GlobalVar:off")
switch("hint", "MsgOrigin:off")
switch("hint", "ProcessingStmt:off")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
