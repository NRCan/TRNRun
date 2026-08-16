switch("mm", "orc")
switch("errorMax", "3")
switch("styleCheck", "hint")
switch("experimental", "strictDefs")

switch("warningAsError", "ProveInit")
switch("warningAsError", "Deprecated")
switch("warningAsError", "UnusedImport")
switch("warningAsError", "CStringConv")
switch("warningAsError", "HoleEnumConv")

# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
