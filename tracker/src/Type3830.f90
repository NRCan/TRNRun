Subroutine Type3830
  !------------------------------------------------------------------------------------
  !    DESCRIPTION
  !------------------------------------------------------------------------------------
  ! Subroutine Type3830 writes TRNSYS simulation timing information to a
  ! `***.tmp` file for external monitoring and post-processing.
  !
  ! The subroutine records:
  !   - Current simulation time (TIME)
  !   - Simulation start time (START)
  !   - Simulation stop time (STOP)
  !   - Current timestep size (STEP)
  !
  ! Version History:
  !   2026-01-01 – A. Lachance: Original implementation.
  !   2026-06-20 – A. Lachance: Modified description
  !
  ! This subroutine can be exported for use in external DLLs.
  !DEC$ATTRIBUTES DLLEXPORT :: TYPE3830
  !------------------------------------------------------------------------------------
  !    VARIABLES
  !------------------------------------------------------------------------------------
  Use TrnsysConstants
  Use TrnsysFunctions
  Implicit None

  Double Precision :: timestep, time
  Double Precision :: sim_start, sim_stop
  Integer :: currentUnit, currentType
  Integer :: lu_print, ios
  Logical :: lu_ok
  Double Precision :: print_interval, next_print_time

  Character(len=maxLabelLength) :: fileName
  Character(len=32) :: LUStr
  Character(len=256) :: Message

  !------------------------------------------------------------------------------------
  !    INITIALIZATION
  !------------------------------------------------------------------------------------
  ! Get global TRNSYS simulation variables
  time = getSimulationTime()
  timestep = getSimulationTimeStep()
  sim_start = getSimulationStartTime()
  sim_stop = getSimulationStopTime()
  currentUnit = getCurrentUnit()
  currentType = getCurrentType()

  !------------------------------------------------------------------------------------
  !    VERSION CHECK
  !------------------------------------------------------------------------------------
  If (getIsVersionSigningTime()) Then
    Call SetTypeVersion(17)
    Return
  End If

  !------------------------------------------------------------------------------------
  !    FINAL CALL HANDLING
  !------------------------------------------------------------------------------------
  If (getIsLastCallofSimulation()) Then
    fileName = getLUFileName(lu_print)
    REWIND (lu_print)
    Write (lu_print, '(F0.10,", ",F0.10,", ",F0.10,", ",F0.10)', ERR=200) time, sim_start, sim_stop, timestep
    Close (lu_print)
    Return
  End If

  !------------------------------------------------------------------------------------
  !    FINAL STEP HANDLING
  !------------------------------------------------------------------------------------
  If (getIsEndOfTimestep()) Then
    next_print_time = getStaticArrayValue(1)

    If (time + timestep/2.d0 >= next_print_time) Then
      fileName = getLUFileName(lu_print)

      REWIND (lu_print)
      Write (lu_print, '(F0.10,", ",F0.10,", ",F0.10,", ",F0.10)', ERR=200) time, sim_start, sim_stop, timestep

      next_print_time = next_print_time + print_interval
      Call SetStaticArrayValue(1, next_print_time)
    End If

    Return
  End If

  !------------------------------------------------------------------------------------
  !    TYPE INITIALIZATION
  !------------------------------------------------------------------------------------
  If (getIsFirstCallofSimulation()) Then
    ! TRNSYS Engine Type Calls
    Call SetNumberofParameters(2)
    Call SetNumberofInputs(0)
    Call SetNumberofDerivatives(0)
    Call SetNumberofOutputs(0)
    Call SetIterationMode(5)
    Call SetNumberStoredVariables(1, 0)
    Call SetNumberofDiscreteControls(0)

    ! TRNSYS Input and Output Units
    ! Nothing

    Return
  End If

  !------------------------------------------------------------------------------------
  !    INITIAL VALUE SETTING
  !------------------------------------------------------------------------------------
  If (getIsStartTime()) Then

    print_interval = getParameterValue(2)
    If (print_interval <= 0) Call FoundBadParameter(2, "Fatal", "Printing interval must be larger than 0")
      If (print_interval < timestep) Call FoundBadParameter(2,"Fatal","Printing interval must be larger or equal than Simulation time step")
    Call SetStaticArrayValue(1, print_interval)

    lu_print = JFIX(getParameterValue(1) + 0.01)
    lu_ok = .false.

    ! If a positive logical unit is specified
    If (lu_print > 0) Then
      ! Reject units less than 10
      If (lu_print >= 10) Then
        lu_ok = LogicalUnitIsOpen(lu_print)
      End If

      ! If no valid logical unit specified, get default listing unit
    Else If (lu_print < 0) Then
      lu_print = getListingFileLogicalUnit()
      lu_ok = .true.
    End If

    ! If logical unit is still not valid, report fatal error
    If (.not. lu_ok) Then
      Write (LUStr, *) lu_print
      Message = "Logical Unit Number = "//TRIM(ADJUSTL(LUStr))
      Call Messages(431, Message, "FATAL", CurrentUnit, CurrentType)
      Return
    End If

    fileName = getLUFileName(lu_print)
    Open (Unit=lu_print, File=fileName, Status="Replace", Action="Write", IOSTAT=ios)

    Return
  End If

  !------------------------------------------------------------------------------------
  !    RE-READ PARAMETERS
  !------------------------------------------------------------------------------------
  If (getIsReReadParameters()) Then
    lu_print = JFIX(getParameterValue(1) + 0.01)
    print_interval = getParameterValue(2)
    fileName = getLUFileName(lu_print)
  End If

  !------------------------------------------------------------------------------------
  !    MAIN TYPE CODE
  !------------------------------------------------------------------------------------
200 Call Messages(431, Message, "FATAL", CurrentUnit, CurrentType)

END SUBROUTINE Type3830
