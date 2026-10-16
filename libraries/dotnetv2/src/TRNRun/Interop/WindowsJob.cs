using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TRNRun.Interop;

/// <summary>Windows Job Object support, so TRNSYS children never outlive this process.</summary>
/// <remarks>
/// <see cref="TryAssign"/> places each freshly started trnrund into a process-wide, kill-on-close
/// Job Object. If this process is killed outright, an orphaned trnrund.exe, and the trnrun.exe
/// and TrnEXE64.exe it drives, could keep running and hold a licence seat; with
/// <c>KILL_ON_JOB_CLOSE</c>, Windows kills the job's members, descendants included, once the
/// last handle closes, which happens automatically when this process dies. The handle is
/// therefore never closed by this package.
/// </remarks>
internal static partial class WindowsJob
{
    private const int JobObjectExtendedLimitInformation = 9;
    private const uint JobObjectLimitKillOnJobClose = 0x2000;

    private static readonly Lock Gate = new();
    private static SafeFileHandle? s_job;
    private static bool s_failed;

    /// <summary>Assigns a freshly started process to the kill-on-close job.</summary>
    /// <remarks>
    /// Best effort: a failure is reported through the return value, never thrown, because losing
    /// orphan cleanup is not a reason to fail a simulation.
    /// </remarks>
    /// <returns>Whether the process was assigned to the job.</returns>
    internal static bool TryAssign(Process process)
    {
        SafeFileHandle? job = Shared;
        if (job is null)
        {
            return false;
        }

        try
        {
            return AssignProcessToJobObject(job, process.SafeHandle);
        }
        catch (Exception error) when (error is InvalidOperationException or Win32Exception)
        {
            return false; // The process already exited, or its handle is unavailable.
        }
    }

    /// <summary>The process-wide job, created on first use; <see langword="null"/> if it could not be created.</summary>
    internal static SafeFileHandle? Shared
    {
        get
        {
            lock (Gate)
            {
                if (s_job is null && !s_failed)
                {
                    s_job = Create();
                    // TRNSYS processes may be orphaned if this process is killed; it is not retried.
                    s_failed = s_job is null;
                }

                return s_job;
            }
        }
    }

    /// <summary>Creates an unnamed job that kills its members when closed; <see langword="null"/> on failure.</summary>
    internal static SafeFileHandle? Create()
    {
        var job = new SafeFileHandle(CreateJobObjectW(0, 0), ownsHandle: true);
        if (job.IsInvalid)
        {
            return null;
        }

        var information = new ExtendedLimitInformation
        {
            BasicLimitInformation = new BasicLimitInformation { LimitFlags = JobObjectLimitKillOnJobClose },
        };
        if (!SetInformationJobObject(
            job, JobObjectExtendedLimitInformation, in information, (uint)Marshal.SizeOf<ExtendedLimitInformation>()))
        {
            job.Dispose();
            return null;
        }

        return job;
    }

    // -----------------------------------------------------------------
    // kernel32 Bindings
    // -----------------------------------------------------------------

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true)]
    private static partial nint CreateJobObjectW(nint jobAttributes, nint name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(
        SafeFileHandle job, int informationClass, in ExtendedLimitInformation information, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(SafeFileHandle job, SafeProcessHandle process);

    // These fields match the Win32 ABI, including fields left zero for this limit class.
#pragma warning disable CS0649
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimitInformation
    {
        public BasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }
#pragma warning restore CS0649
}
