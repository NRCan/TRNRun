switch("mm", "orc")
switch("threads", "on")
switch("errorMax", "3")
switch("styleCheck", "error")
switch("experimental", "strictDefs")
switch("experimental", "strictFuncs")
switch("experimental", "strictEffects")

switch("warningAsError", "ProveInit")
switch("warningAsError", "Deprecated")
switch("warningAsError", "UnusedImport")
switch("warningAsError", "CStringConv")
switch("warningAsError", "HoleEnumConv")
switch("warningAsError", "UnreachableCode")
switch("warningAsError", "ResultShadowed")
switch("warningAsError", "StdPrefix")
switch("warningAsError", "UnnamedBreak")
switch("warningAsError", "CaseTransition")
switch("warningAsError", "EnumConv")
switch("warningAsError", "CastSizes")
switch("warningAsError", "ImplicitTemplateRedefinition")
switch("warningAsError", "GcUnsafe2")

# Some of these are off by default; warningAsError alone does not enable them.
switch("warning", "UnreachableCode:on")
switch("warning", "ResultShadowed:on")
switch("warning", "StdPrefix:on")
switch("warning", "UnnamedBreak:on")
switch("warning", "CaseTransition:on")
switch("warning", "EnumConv:on")
switch("warning", "CastSizes:on")
switch("warning", "ImplicitTemplateRedefinition:on")
switch("warning", "GcUnsafe2:on")

switch("hintAsError", "XDeclaredButNotUsed")
switch("hintAsError", "DuplicateModuleImport")
switch("hintAsError", "ConvFromXtoItselfNotNeeded")
switch("hintAsError", "ExprAlwaysX")

switch("hint", "XDeclaredButNotUsed:on")
switch("hint", "DuplicateModuleImport:on")
switch("hint", "ConvFromXtoItselfNotNeeded:on")
switch("hint", "ExprAlwaysX:on")

switch("hint", "GlobalVar:off")
switch("hint", "MsgOrigin:off")
switch("hint", "ProcessingStmt:off")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config
