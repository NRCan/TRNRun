# MATLAB Windows Job Object interop

This directory contains the source for `TrnRun.Interop.dll`, a minimal AnyCPU
.NET Framework assembly intended for MATLAB R2022b on 64-bit Windows. It uses
only .NET Framework and Win32 APIs; no NuGet or other external packages are
required.

`TrnRun.Interop.KillOnCloseJob` creates one unnamed Job Object per instance and
enables `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. Closing or finalizing an instance
therefore terminates all processes assigned to that job. `Terminate(uint)` can
terminate the job explicitly before disposal.

## Build

Run the script with Windows PowerShell 5.1 from any directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\libraries\matlab\interop\build.ps1
```

The script locates the installed .NET Framework 4.x `csc.exe`, compiles with
`/platform:anycpu`, and writes:

```text
libraries/matlab/bin/win64/TrnRun.Interop.dll
```

For compile-only checks that should not write into the repository, override the
output directory:

```powershell
.\libraries\matlab\interop\build.ps1 -OutputDirectory C:\Temp\TrnRunInterop
```

The DLL is a build artifact and must not be committed.

## MATLAB runtime use

Load the assembly by absolute path before constructing the class:

```matlab
assemblyPath = fullfile(repoRoot, "libraries", "matlab", "bin", ...
    "win64", "TrnRun.Interop.dll");
NET.addAssembly(assemblyPath);

job = TrnRun.Interop.KillOnCloseJob();
process = System.Diagnostics.Process();
process.StartInfo.FileName = "C:\path\to\program.exe";
process.Start();
job.Assign(process);
```

Keep `job` reachable for as long as the child process should be allowed to run.
Calling `job.Dispose()`, clearing the last reference and allowing finalization,
or exiting MATLAB closes the job handle and terminates assigned processes. To
terminate the job explicitly, call `job.Terminate(uint32(exitCode))`.

`Assign` requires a started process and sufficient rights to its native handle.
Assignment can also fail if the process is already in an incompatible job. Such
native failures are reported as `System.ComponentModel.Win32Exception` with the
operation, context, numeric Win32 error code, and system error text.

Do not assign the MATLAB process itself unless terminating MATLAB when the job
is closed is intentional.

## Validation status

MATLAB R2022b load and runtime behavior validation is pending on a Windows host
with MATLAB R2022b installed. Run the build command above, load the resulting
assembly, and exercise both normal disposal and explicit termination before
relying on it in production workflows.
