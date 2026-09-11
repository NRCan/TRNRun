using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TrnRun.Interop
{
    /// <summary>
    /// Owns an unnamed Windows Job Object that terminates its assigned processes
    /// when the job's last handle is closed.
    /// </summary>
    public sealed class KillOnCloseJob : IDisposable
    {
        private readonly object syncRoot = new object();
        private SafeJobHandle jobHandle;

        public KillOnCloseJob()
        {
            SafeJobHandle newJobHandle = NativeMethods.CreateJobObject(IntPtr.Zero, null);
            if (newJobHandle == null || newJobHandle.IsInvalid)
            {
                Win32Exception exception = CreateWin32Exception(
                    "CreateJobObjectW",
                    "creating an unnamed job object");

                if (newJobHandle != null)
                {
                    newJobHandle.Dispose();
                }

                throw exception;
            }

            try
            {
                NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION information =
                    new NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                information.BasicLimitInformation.LimitFlags =
                    NativeMethods.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

                int informationLength = Marshal.SizeOf(
                    typeof(NativeMethods.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));

                if (!NativeMethods.SetInformationJobObject(
                    newJobHandle,
                    NativeMethods.JobObjectExtendedLimitInformation,
                    ref information,
                    informationLength))
                {
                    throw CreateWin32Exception(
                        "SetInformationJobObject",
                        "enabling JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE");
                }

                jobHandle = newJobHandle;
                newJobHandle = null;
            }
            finally
            {
                if (newJobHandle != null)
                {
                    newJobHandle.Dispose();
                }
            }
        }

        ~KillOnCloseJob()
        {
            Dispose(false);
        }

        /// <summary>
        /// Assigns a process to this job object.
        /// </summary>
        /// <param name="process">A started process that the caller is permitted to assign.</param>
        public void Assign(Process process)
        {
            if (process == null)
            {
                throw new ArgumentNullException("process");
            }

            int processId;
            SafeProcessHandle processHandle;

            try
            {
                processId = process.Id;
                processHandle = process.SafeHandle;
            }
            catch (InvalidOperationException exception)
            {
                throw new InvalidOperationException(
                    "The process must be started and have an accessible native handle before it can be assigned to the job.",
                    exception);
            }

            lock (syncRoot)
            {
                ThrowIfDisposed();

                if (!NativeMethods.AssignProcessToJobObject(jobHandle, processHandle))
                {
                    throw CreateWin32Exception(
                        "AssignProcessToJobObject",
                        "assigning process " + processId +
                        ". The process may already be in an incompatible job, or the caller may lack PROCESS_SET_QUOTA and PROCESS_TERMINATE access");
                }
            }
        }

        /// <summary>
        /// Terminates every process currently associated with this job object.
        /// </summary>
        /// <param name="exitCode">The exit code reported by terminated processes.</param>
        public void Terminate(uint exitCode)
        {
            lock (syncRoot)
            {
                ThrowIfDisposed();

                if (!NativeMethods.TerminateJobObject(jobHandle, exitCode))
                {
                    throw CreateWin32Exception(
                        "TerminateJobObject",
                        "terminating the job with exit code " + exitCode);
                }
            }
        }

        public void Dispose()
        {
            Dispose(true);
            GC.SuppressFinalize(this);
        }

        private void Dispose(bool disposing)
        {
            lock (syncRoot)
            {
                if (jobHandle == null)
                {
                    return;
                }

                jobHandle.Dispose();
                jobHandle = null;
            }
        }

        private void ThrowIfDisposed()
        {
            if (jobHandle == null)
            {
                throw new ObjectDisposedException(typeof(KillOnCloseJob).FullName);
            }
        }

        private static Win32Exception CreateWin32Exception(string operation, string context)
        {
            int errorCode = Marshal.GetLastWin32Error();
            string nativeMessage = new Win32Exception(errorCode).Message;
            string message = operation + " failed while " + context +
                ". Win32 error " + errorCode + ": " + nativeMessage;
            return new Win32Exception(errorCode, message);
        }

        private sealed class SafeJobHandle : SafeHandleZeroOrMinusOneIsInvalid
        {
            private SafeJobHandle()
                : base(true)
            {
            }

            protected override bool ReleaseHandle()
            {
                return NativeMethods.CloseHandle(handle);
            }
        }

        private static class NativeMethods
        {
            internal const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
            internal const int JobObjectExtendedLimitInformation = 9;

            [StructLayout(LayoutKind.Sequential)]
            internal struct JOBOBJECT_BASIC_LIMIT_INFORMATION
            {
                internal long PerProcessUserTimeLimit;
                internal long PerJobUserTimeLimit;
                internal uint LimitFlags;
                internal UIntPtr MinimumWorkingSetSize;
                internal UIntPtr MaximumWorkingSetSize;
                internal uint ActiveProcessLimit;
                internal UIntPtr Affinity;
                internal uint PriorityClass;
                internal uint SchedulingClass;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct IO_COUNTERS
            {
                internal ulong ReadOperationCount;
                internal ulong WriteOperationCount;
                internal ulong OtherOperationCount;
                internal ulong ReadTransferCount;
                internal ulong WriteTransferCount;
                internal ulong OtherTransferCount;
            }

            [StructLayout(LayoutKind.Sequential)]
            internal struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
            {
                internal JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
                internal IO_COUNTERS IoInfo;
                internal UIntPtr ProcessMemoryLimit;
                internal UIntPtr JobMemoryLimit;
                internal UIntPtr PeakProcessMemoryUsed;
                internal UIntPtr PeakJobMemoryUsed;
            }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
            internal static extern SafeJobHandle CreateJobObject(
                IntPtr jobAttributes,
                string name);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool SetInformationJobObject(
                SafeJobHandle job,
                int informationClass,
                ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information,
                int informationLength);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool AssignProcessToJobObject(
                SafeJobHandle job,
                SafeProcessHandle process);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool TerminateJobObject(
                SafeJobHandle job,
                uint exitCode);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            internal static extern bool CloseHandle(IntPtr handle);
        }
    }
}
