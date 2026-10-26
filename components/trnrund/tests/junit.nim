# Imported by every test file so CI can publish a summary; writes TestResults/nim/<component>-<test>.xml.
{.used.}

import std/[compilesettings, exitprocs, os, streams, unittest]

const
  testsDir = currentSourcePath().parentDir
  reportName = testsDir.parentDir.lastPathPart & "-" & querySetting(projectName) & ".xml"
  reportDir = testsDir.parentDir.parentDir.parentDir / "TestResults" / "nim"

# Several tests relaunch themselves with arguments as fake child processes, which must not
# overwrite the parent's report; nimble test runs each test without arguments.
if paramCount() == 0:
  createDir(reportDir)
  let junit = newJUnitOutputFormatter(newFileStream(reportDir / reportName, fmWrite))
  # Adding any formatter drops the default console one, so add it back first.
  addOutputFormatter(defaultConsoleFormatter())
  addOutputFormatter(junit)
  addExitProc(proc() = junit.close())
