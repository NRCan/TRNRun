using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TRNRun.Interop;

// One non-inheritable handle per queue. Assignment happens before any requests are sent,
// so the queue cannot launch children before joining the job.
internal sealed partial class WindowsJobObject : SafeHandleZeroOrMinusOneIsInvalid
{
    private WindowsJobObject(nint handle) : base(ownsHandle: true)
    {
        SetHandle(handle);
    }

    internal static WindowsJobObject? TryAssign(Process process)
    {
        WindowsJobObject? job = null;
        try
        {
            job = new WindowsJobObject(CreateJobObjectW(0, 0));
            if (job.IsInvalid)
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "CreateJobObjectW failed.");
            }

            var information = new ExtendedLimitInformation
            {
                BasicLimitInformation = new BasicLimitInformation { LimitFlags = 0x2000 },
            };
            if (!SetInformationJobObject(job, 9, in information,
                (uint)Marshal.SizeOf<ExtendedLimitInformation>()))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "SetInformationJobObject failed.");
            }

            if (!AssignProcessToJobObject(job, process.SafeHandle))
            {
                throw new Win32Exception(Marshal.GetLastPInvokeError(), "AssignProcessToJobObject failed.");
            }

            return job;
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException)
        {
            job?.Dispose();
            try
            {
                Console.Error.WriteLine(
                    $"TRNRun warning: Windows Job Object protection is unavailable: {error.Message} "
                    + "The queue and TRNSYS children may survive an unexpected host exit.");
            }
            catch (Exception outputError) when (outputError is IOException or ObjectDisposedException)
            {
                // A missing diagnostic stream must not turn best-effort protection into a launch failure.
            }

            return null;
        }
    }

    protected override bool ReleaseHandle() => CloseHandle(handle);

    [LibraryImport("kernel32.dll", EntryPoint = "CreateJobObjectW", SetLastError = true)]
    private static partial nint CreateJobObjectW(nint jobAttributes, nint name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(
        WindowsJobObject job, int informationClass, in ExtendedLimitInformation information, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(WindowsJobObject job, SafeProcessHandle process);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

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
