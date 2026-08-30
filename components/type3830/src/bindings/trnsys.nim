## TRNSYS bindings and Nim-friendly overloads.

import std/strutils

# =============================================================================
# TRNSYS bindings
# =============================================================================
# ------------------------------------------------------------
# Kernel subroutines
# ------------------------------------------------------------
# proc foundBadInput*(input: ptr cint, severity: cstring, message: cstring, severityLen: csize_t, messageLen: csize_t) {.cdecl, importc: "FOUNDBADINPUT".}
proc foundBadParameter*(param: ptr cint, severity: cstring, message: cstring, severityLen: csize_t, messageLen: csize_t) {.cdecl, importc: "FOUNDBADPARAMETER".}

# proc initReportIntegral*(index: ptr cint, intName: cstring, instUnit: cstring, intUnit: cstring, nameLen: csize_t, unitLen: csize_t, integralUnitLen: csize_t) {.cdecl, importc: "INITREPORTINTEGRAL".}
# proc initReportMinMax*(index: ptr cint, minMaxName: cstring, minMaxUnit: cstring, nameLen: csize_t, unitLen: csize_t) {.cdecl, importc: "INITREPORTMINMAX".}
# proc initReportText*(index: ptr cint, textName: cstring, textValue: cstring, nameLen: csize_t, valueLen: csize_t) {.cdecl, importc: "INITREPORTTEXT".}
# proc initReportValue*(index: ptr cint, valueName: cstring, value: ptr cdouble, valueUnit: cstring, nameLen: csize_t, unitLen: csize_t) {.cdecl, importc: "INITREPORTVALUE".}
# proc readNextChar*(lun: ptr cint): cint {.cdecl, importc: "READNEXTCHAR".}
#
# proc setDesiredDiscreteControlState*(i, j: ptr cint) {.cdecl, importc: "SETDESIREDDISCRETECONTROLSTATE".}
# proc setDynamicArrayInitialValue*(i: ptr cint, value: ptr cdouble) {.cdecl, importc: "SETDYNAMICARRAYINITIALVALUE".}
# proc setDynamicArrayValueThisIteration*(i: ptr cint, value: ptr cdouble) {.cdecl, importc: "SETDYNAMICARRAYVALUETHISITERATION".}
# proc setInputUnits*(i: ptr cint, s: cstring, len: csize_t) {.cdecl, importc: "SETINPUTUNITS".}
proc setIterationMode*(i: ptr cint) {.cdecl, importc: "SETITERATIONMODE".}
proc setNumberOfDerivatives*(i: ptr cint) {.cdecl, importc: "SETNUMBEROFDERIVATIVES".}
proc setNumberOfDiscreteControls*(i: ptr cint) {.cdecl, importc: "SETNUMBEROFDISCRETECONTROLS".}

proc setNumberOfInputs*(i: ptr cint) {.cdecl, importc: "SETNUMBEROFINPUTS".}
proc setNumberOfOutputs*(i: ptr cint) {.cdecl, importc: "SETNUMBEROFOUTPUTS".}
proc setNumberOfParameters*(i: ptr cint) {.cdecl, importc: "SETNUMBEROFPARAMETERS".}
# proc setNumberOfReportVariables*(nInt, nMinMax, nVals, nText: ptr cint) {.cdecl, importc: "SETNUMBEROFREPORTVARIABLES".}
proc setNumberStoredVariables*(requestedStatic, requestedDynamic: ptr cint) {.cdecl, importc: "SETNUMBERSTOREDVARIABLES".}

# proc setNumericalDerivative*(i: ptr cint, value: ptr cdouble) {.cdecl, importc: "SETNUMERICALDERIVATIVE".}
# proc setOutputUnits*(i: ptr cint, s: cstring, len: csize_t) {.cdecl, importc: "SETOUTPUTUNITS".}
# proc setOutputValue*(i: ptr cint, value: ptr cdouble) {.cdecl, importc: "SETOUTPUTVALUE".}
# proc setStaticArrayValue*(i: ptr cint, value: ptr cdouble) {.cdecl, importc: "SETSTATICARRAYVALUE".}
proc setTypeVersion*(i: ptr cint) {.cdecl, importc: "SETTYPEVERSION".}

# proc errorFound*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_ERRORFOUND".}
# proc getConvergenceTolerance*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETCONVERGENCETOLERANCE".}
proc getCurrentType*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETCURRENTTYPE".}
proc getCurrentUnit*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETCURRENTUNIT".}
# proc getDeckFileName*(dck: cstring, len: csize_t): cstring {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETDECKFILENAME".}
# proc getDynamicArrayValueLastTimestep*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETDYNAMICARRAYVALUELASTTIMESTEP".}
# proc getFormat*(label: cstring, labelLen: csize_t, unit, number: ptr cint): cstring {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETFORMAT".}
# proc getInputValue*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETINPUTVALUE".}
proc getIsEndOfTimestep*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISENDOFTIMESTEP".}

proc getIsFirstCallOfSimulation*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISFIRSTCALLOFSIMULATION".}

# proc getIsIncludedInSSR*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISINCLUDEDINSSR".}
proc getIsLastCallOfSimulation*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISLASTCALLOFSIMULATION".}

proc getIsReReadParameters*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISREREADPARAMETERS".}

proc getIsStartTime*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISSTARTTIME".}
proc getIsVersionSigningTime*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETISVERSIONSIGNINGTIME".}

# proc getLabel*(label: cstring, labelLen: csize_t, unit, number: ptr cint): cstring {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETLABEL".}
# proc getLUFileName*(name: cstring, nameLen: csize_t, logicalUnit: ptr cint): cstring {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETLUFILENAME".}
# proc getMaxDescripLength*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETMAXDESCRIPLENGTH".}
# proc getMaxLabelLength*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETMAXLABELLENGTH".}
proc getMaxPathLength*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETMAXPATHLENGTH".}
# proc getMinimumTimestep*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETMINIMUMTIMESTEP".}
# proc getNextAvailableLogicalUnit*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNEXTAVAILABLELOGICALUNIT".}
# proc getNumberOfDerivatives*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMBEROFDERIVATIVES".}
# proc getNumberOfInputs*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMBEROFINPUTS".}
# proc getNumberOfLabels*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMBEROFLABELS".}
# proc getNumberOfOutputs*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMBEROFOUTPUTS".}
# proc getNumberOfParameters*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMBEROFPARAMETERS".}
# proc getNumericalSolution*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETNUMERICALSOLUTION".}
# proc getOutputValue*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETOUTPUTVALUE".}
proc getParameterValue*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETPARAMETERVALUE".}

# proc getPreviousControlState*(i: ptr cint): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETPREVIOUSCONTROLSTATE".}
proc getSimulationStartTime*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETSIMULATIONSTARTTIME".}

proc getSimulationStopTime*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETSIMULATIONSTOPTIME".}

proc getSimulationTime*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETSIMULATIONTIME".}

proc getSimulationTimeStep*(): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETSIMULATIONTIMESTEP".}

# proc getStaticArrayValue*(i: ptr cint): cdouble {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETSTATICARRAYVALUE".}
# proc getTimestepIteration*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETTIMESTEPITERATION".}
# proc getTrnsysInputFileDir*(directory: cstring, directoryLen: csize_t): cstring {.cdecl, importc: "TRNSYFUNCTIONS_mp_GETTRNSYSINPUTFILEDIR".}  # note: typo in original symbol
# proc getTrnsysRootDir*(directory: cstring, directoryLen: csize_t): cstring {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETTRNSYSROOTDIR".}
#
# proc updateReportIntegral*(index: ptr cint, intVal: ptr cdouble) {.cdecl, importc: "UPDATEREPORTINTEGRAL".}
# proc updateReportMinMax*(index: ptr cint, newVal: ptr cdouble) {.cdecl, importc: "UPDATEREPORTMINMAX".}
# proc typeck*(iopt, info, numberOfInputs, numberOfParameters, numberOfDerivatives: ptr cint) {.cdecl, importc: "TYPECK".}
#
# proc getListingFileLogicalUnit*(): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETLISTINGFILELOGICALUNIT".}
proc getLUFileNameCpp*(logicalUnit: ptr cint, filePath: cstring, pathLen: csize_t): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_GETLUFILENAME_CPP".}

proc logicalUnitIsOpen*(logicalUnit: ptr cint): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_LOGICALUNITISOPEN".}

proc closeFileIVF*(logicalUnit: ptr cint): cint {.cdecl, importc: "TRNSYSFUNCTIONS_mp_CLOSEFILEIVF".}

# ------------------------------------------------------------
# TRNSYS subroutines
# ------------------------------------------------------------
# proc fluidProperties*(units: cstring, properties: ptr cdouble, referenceCount, propertyType, errorFlag: ptr cint, unitsLen: csize_t) {.cdecl, importc: "FLUID_PROPERTIES".}
# proc getHorizontalRadiation*(time: ptr cdouble, radiationMode, shapeMode: ptr cint, radiationInput: ptr cdouble, groundReflectance, slope, azimuth: ptr cdouble, trackingMode, tiltMode: ptr cint, latitude, altitude, shift: ptr cdouble, solarTimeMode: ptr cint, solarConstant, td1, td2: ptr cdouble, solar: ptr cdouble, radiationError: ptr cint) {.cdecl, importc: "GETHORIZONTALRADIATION".}
# proc getTiltedRadiation*(time, groundReflectance, slope, azimuth: ptr cdouble, trackingMode, tiltMode: ptr cint, altitude, solarConstant: ptr cdouble, solar: ptr cdouble, radiationError: ptr cint) {.cdecl, importc: "GETTILTEDRADIATION".}
# proc interpolateData*(logicalUnit, independentVariableCount, xCount, yCount: ptr cint, x, y: ptr cdouble) {.cdecl, importc: "INTERPOLATEDATA".}
proc messages*(errorCode: ptr cint, message, severity: cstring, unitNo, typeNo: ptr cint, n, m: csize_t) {.cdecl, importc: "MESSAGES".}

# proc moistAirProperties*(currentUnit, currentType, units, mode, wetBulbMode: ptr cint, psychrometricData: ptr cdouble, errorMode, status: ptr cint) {.cdecl, importc: "MOISTAIRPROPERTIES".}
# proc solveDiffEq*(aa, bb, initialTemperature, finalTemperature, averageTemperature: ptr cdouble) {.cdecl, importc: "SOLVEDIFFEQ".}
# proc steamProperties*(units: cstring, properties: ptr cdouble, propertyType, errorStatus: ptr cint, unitsLen: csize_t) {.cdecl, importc: "STEAM_PROPERTIES".}

# =============================================================================
# Nim-friendly Overloads
# =============================================================================
# ------------------------------------------------------------
# Type configuration
# ------------------------------------------------------------
proc setNumberOfParameters*(numberOfParameters: cint) =
  var value = numberOfParameters
  setNumberOfParameters(addr value)

proc setNumberOfInputs*(numberOfInputs: cint) =
  var value = numberOfInputs
  setNumberOfInputs(addr value)

proc setNumberOfDerivatives*(numberOfDerivatives: cint) =
  var value = numberOfDerivatives
  setNumberOfDerivatives(addr value)

proc setNumberOfOutputs*(numberOfOutputs: cint) =
  var value = numberOfOutputs
  setNumberOfOutputs(addr value)

proc setNumberOfDiscreteControls*(numberOfDiscreteControls: cint) =
  var value = numberOfDiscreteControls
  setNumberOfDiscreteControls(addr value)

proc setIterationMode*(mode: cint) =
  var iterationMode = mode
  setIterationMode(addr iterationMode)

proc setTypeVersion*(version: cint) =
  var typeVersion = version
  setTypeVersion(addr typeVersion)

proc setNumberStoredVariables*(staticVariableCount, dynamicVariableCount: cint) =
  var staticCount = staticVariableCount
  var dynamicCount = dynamicVariableCount
  setNumberStoredVariables(addr staticCount, addr dynamicCount)

# ------------------------------------------------------------
# Values
# ------------------------------------------------------------
proc getParameterValue*(index: cint): cdouble =
  var parameterIndex = index
  getParameterValue(addr parameterIndex)

# proc getInputValue*(index: cint): cdouble =
#   var inputIndex = index
#   getInputValue(addr inputIndex)
#
# proc getOutputValue*(index: cint): cdouble =
#   var outputIndex = index
#   getOutputValue(addr outputIndex)
#
# proc setOutputValue*(index: cint, value: cdouble) =
#   var outputIndex = index
#   var outputValue = value
#   setOutputValue(addr outputIndex, addr outputValue)
#
# proc getStaticArrayValue*(slot: cint): cdouble =
#   var staticSlot = slot
#   getStaticArrayValue(addr staticSlot)
#
# proc setStaticArrayValue*(slot: cint, value: cdouble) =
#   var staticSlot = slot
#   var staticValue = value
#   setStaticArrayValue(addr staticSlot, addr staticValue)

# ------------------------------------------------------------
# Logical units
# ------------------------------------------------------------
proc logicalUnitIsOpen*(logicalUnit: cint): bool =
  var unit = logicalUnit
  logicalUnitIsOpen(addr unit) != 0

proc closeFileIVF*(logicalUnit: cint): cint {.discardable.} =
  var unit = logicalUnit
  closeFileIVF(addr unit)

proc getLUFileName*(logicalUnit: cint): string =
  ## Returns an empty string when no file is assigned to the logical unit.
  var unit = logicalUnit
  let maxPathLength = getMaxPathLength().int

  if maxPathLength <= 0:
    return ""

  var buffer = newString(maxPathLength)
  let written =
    getLUFileNameCpp(addr unit, cast[cstring](buffer[0].addr), maxPathLength.csize_t)

  if written <= 0:
    return ""

  buffer.setLen(min(written.int, maxPathLength))
  buffer.strip(chars = {' ', '\0', '\t'})

# ------------------------------------------------------------
# Messages
# ------------------------------------------------------------
proc trnsysMessage*(
    code: cint, message, severity: string, currentUnit, currentType: cint
) =
  ## Hidden character lengths go last, in declaration order.
  var messageCode = code
  var unit = currentUnit
  var trnsysType = currentType
  messages(
    addr messageCode,
    message.cstring,
    severity.cstring,
    addr unit,
    addr trnsysType,
    message.len.csize_t,
    severity.len.csize_t,
  )

proc foundBadParameter*(index: cint, severity, message: string) =
  var parameterIndex = index
  foundBadParameter(
    addr parameterIndex,
    severity.cstring,
    message.cstring,
    severity.len.csize_t,
    message.len.csize_t,
  )

# proc foundBadInput*(index: cint, severity, message: string) =
#   var inputIndex = index
#   foundBadInput(addr inputIndex, severity.cstring, message.cstring, severity.len.csize_t, message.len.csize_t)

proc trnsysFatal*(code: cint, message: string) {.inline.} =
  trnsysMessage(code, message, "FATAL", getCurrentUnit(), getCurrentType())
