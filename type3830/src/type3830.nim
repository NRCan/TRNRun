# =============================================================================
# DESCRIPTION
# =============================================================================
# Subroutine Type3830 writes TRNSYS simulation timing information to a
# `***.tmp` file for external monitoring and post-processing.
#
# The subroutine records:
#   - Current simulation time (TIME)
#   - Simulation start time (START)
#   - Simulation stop time (STOP)
#   - Current timestep size (STEP)
#
# Only one instance of Type3830 may be used in a simulation.
#
# Version history:
#   2026-01-01 – A. Lachance: Original implementation.
#   2026-06-20 – A. Lachance: Updated description.
#   2026-08-13 – A. Lachance: Converted to Nim.
#   2026-08-15 – A. Lachance: Optimized runtime access and file writing.

import std/strformat

import bindings/trnsys

var
  timingFile: File
  printInterval: cdouble
  nextPrintTime: cdouble
  simulationStart: cdouble
  simulationStop: cdouble
  simulationStep: cdouble

proc discardTimingFile() =
  if timingFile != nil:
    try:
      timingFile.close()
    except CatchableError:
      discard
    timingFile = nil

proc writeTimingRecord(time: cdouble; closeAfter: bool = false): bool =
  result = false

  if timingFile == nil:
    return false

  try:
    timingFile.setFilePos(0)
    timingFile.write(&"{time:22.10f}, {simulationStart:22.10f}, {simulationStop:22.10f}, {simulationStep:22.10f}\n")

    if closeAfter:
      timingFile.close()
      timingFile = nil
    else:
      timingFile.flushFile()

    result = true
  except CatchableError:
    let errorMessage = getCurrentExceptionMsg()

    discardTimingFile()
    trnsysFatal(431, "Type3830 file operation failed: " & errorMessage)

proc TYPE3830() {.cdecl, exportc: "TYPE3830", dynlib.} =
  # ------------------------------------------------------------
  # VERSION
  # ------------------------------------------------------------
  if getIsVersionSigningTime() != 0:
    setTypeVersion(17)
    return

  # ------------------------------------------------------------
  # END OF SIMULATION
  # ------------------------------------------------------------
  if getIsLastCallOfSimulation() != 0:
    discard writeTimingRecord(getSimulationTime(), true)
    return

  # ------------------------------------------------------------
  # END OF TIMESTEP
  # ------------------------------------------------------------
  if getIsEndOfTimestep() != 0:
    if timingFile == nil:
      return

    let time = getSimulationTime()

    if time + simulationStep * 0.5 < nextPrintTime:
      return

    if writeTimingRecord(time):
      nextPrintTime += printInterval

    return
  # ------------------------------------------------------------
  # INITIALIZATION
  # ------------------------------------------------------------
  if getIsFirstCallOfSimulation() != 0:
    setNumberOfParameters(2)
    setNumberOfInputs(0)
    setNumberOfDerivatives(0)
    setNumberOfOutputs(0)
    setIterationMode(5)
    setNumberStoredVariables(0, 0)
    setNumberOfDiscreteControls(0)
    return

  # ------------------------------------------------------------
  # START OF SIMULATION
  # ------------------------------------------------------------
  if getIsStartTime() != 0:
    simulationStart = getSimulationStartTime()
    simulationStop = getSimulationStopTime()
    simulationStep = getSimulationTimeStep()
    printInterval = getParameterValue(2)

    if printInterval <= 0.0:
      foundBadParameter(2, "Fatal", "Printing interval must be greater than 0")
      return

    if printInterval < simulationStep:
      foundBadParameter(2, "Fatal", "Printing interval must be greater than or equal to the simulation timestep")
      return

    nextPrintTime = simulationStart + printInterval

    let luPrint = cint(getParameterValue(1) + 0.01)

    if luPrint < 10:
      trnsysFatal(431, "Logical unit must be 10 or greater; got " & $luPrint)
      return

    if not logicalUnitIsOpen(luPrint):
      trnsysFatal(431, "Logical unit " & $luPrint & " is not open")
      return

    let fileName = getLUFileName(luPrint)

    if fileName.len == 0:
      trnsysFatal(431, "No file is assigned to logical unit " & $luPrint)
      return

    try:
      discardTimingFile()
      closeFileIVF(luPrint)

      if not open(timingFile, fileName, fmWrite):
        timingFile = nil
        trnsysFatal(431, "Unable to open timing file: " & fileName)
        return

      discard writeTimingRecord(getSimulationTime())
    except CatchableError:
      let errorMessage = getCurrentExceptionMsg()

      discardTimingFile()
      trnsysFatal(431, "Type3830 file operation failed: " & errorMessage)

    return

  # ------------------------------------------------------------
  # RE-READ PARAMETERS
  # ------------------------------------------------------------
  if getIsReReadParameters() != 0:
    discard

  # ------------------------------------------------------------
  # MAIN CODE
  # ------------------------------------------------------------
  # This type has no main calculation.
