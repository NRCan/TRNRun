switch("mm", "orc")
switch("threads", "on")
switch("errorMax", "3")
switch("styleCheck", "hint")
switch("experimental", "strictDefs")

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
