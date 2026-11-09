using System.IO;
using System.ComponentModel;
using System.Globalization;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ZeroOne.CodexPipeProbe;

internal sealed class PipeChild : IDisposable
{
    private const string IoSwitch = "--remote-debugging-io-pipes=";
    private const uint ExtendedStartupInfoPresent = 0x00080000;
    private const int HandleListAttribute = 0x00020002;
    private readonly SafeProcessHandle process;

    private PipeChild(NamedPipeServerStream input, NamedPipeServerStream output,
                      SafeProcessHandle process, uint pid)
    {
        Input = input;
        Output = output;
        this.process = process;
        Pid = pid;
    }

    // Directions are relative to the launcher.
    public NamedPipeServerStream Input { get; }
    public NamedPipeServerStream Output { get; }
    public uint Pid { get; }

    public static PipeChild Start(string executable, bool mock = false)
    {
        string requestName = $"zero-one-cdp-{Guid.NewGuid():N}";
        string replyName = $"zero-one-cdp-{Guid.NewGuid():N}";
        var requests = MakeServer(requestName, PipeDirection.Out);
        NamedPipeServerStream? replies = null;
        try
        {
            replies = MakeServer(replyName, PipeDirection.In);
            using var childInput = ConnectChildEnd(requestName, PipeDirection.In, requests);
            using var childOutput = ConnectChildEnd(replyName, PipeDirection.Out, replies);
            var readHandle = childInput.SafePipeHandle.DangerousGetHandle();
            var writeHandle = childOutput.SafePipeHandle.DangerousGetHandle();

            // Chromium adopts inherited Windows HANDLEs from this switch in read,write order.
            string handles = $"{HandleArgument(readHandle)},{HandleArgument(writeHandle)}";
            string mockArg = mock ? " --mock-child" : "";
            var commandLine = new StringBuilder(
                $"\"{executable}\"{mockArg} --remote-debugging-pipe {IoSwitch}{handles}");
            var child = Spawn(executable, commandLine, readHandle, writeHandle);
            return new PipeChild(replies, requests, new SafeProcessHandle(child.Process, true), child.Pid);
        }
        catch
        {
            replies?.Dispose();
            requests.Dispose();
            throw;
        }
    }

    internal static (IntPtr Read, IntPtr Write) ReadHandleArguments(string[] args)
    {
        string[] handles = args.Single(arg => arg.StartsWith(IoSwitch, StringComparison.Ordinal))
            [IoSwitch.Length..].Split(',');
        return ((IntPtr)long.Parse(handles[0], CultureInfo.InvariantCulture),
                (IntPtr)long.Parse(handles[1], CultureInfo.InvariantCulture));
    }

    private static string HandleArgument(IntPtr handle) =>
        checked((uint)handle.ToInt64()).ToString(CultureInfo.InvariantCulture);

    private static NamedPipeServerStream MakeServer(string name, PipeDirection direction) =>
        new(name, direction, 1, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);

    private static NamedPipeClientStream ConnectChildEnd(
        string name, PipeDirection direction, NamedPipeServerStream server)
    {
        // Chromium uses synchronous ReadFile/WriteFile on the child ends.
        var client = new NamedPipeClientStream(".", name, direction, PipeOptions.None,
            TokenImpersonationLevel.Identification, HandleInheritability.Inheritable);
        try
        {
            client.Connect(2000);
            server.WaitForConnection();
            return client;
        }
        catch
        {
            client.Dispose();
            throw;
        }
    }

    private static ProcessInformation Spawn(
        string executable, StringBuilder commandLine, IntPtr readHandle, IntPtr writeHandle)
    {
        nuint size = 0;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
        if (size == 0)
            throw Win32Error("InitializeProcThreadAttributeList (size)");

        IntPtr attributes = Marshal.AllocHGlobal(checked((nint)size));
        try
        {
            if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                throw Win32Error("InitializeProcThreadAttributeList");

            try
            {
                IntPtr handles = Marshal.AllocHGlobal(2 * IntPtr.Size);
                try
                {
                    Marshal.WriteIntPtr(handles, readHandle);
                    Marshal.WriteIntPtr(handles, IntPtr.Size, writeHandle);
                    if (!UpdateProcThreadAttribute(attributes, 0, HandleListAttribute, handles,
                                                   (nuint)(2 * IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                        throw Win32Error("UpdateProcThreadAttribute(HANDLE_LIST)");

                    var startup = new StartupInfoEx
                    {
                        Info = new StartupInfo { Size = Marshal.SizeOf<StartupInfoEx>() },
                        AttributeList = attributes
                    };
                    if (!CreateProcess(executable, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                                       ExtendedStartupInfoPresent, IntPtr.Zero,
                                       Path.GetDirectoryName(executable)!, ref startup, out var child))
                        throw Win32Error("CreateProcessW");

                    using var thread = new SafeWaitHandle(child.Thread, true);
                    return child;
                }
                finally { Marshal.FreeHGlobal(handles); }
            }
            finally { DeleteProcThreadAttributeList(attributes); }
        }
        finally { Marshal.FreeHGlobal(attributes); }
    }

    public void Disconnect()
    {
        Output.Dispose();
        Input.Dispose();
    }

    public bool WaitForExit(uint milliseconds)
    {
        return WaitForSingleObject(process, milliseconds) switch
        {
            0 => true,
            258 => false,
            _ => throw Win32Error("WaitForSingleObject")
        };
    }

    public uint ExitCode => GetExitCodeProcess(process, out uint code)
        ? code : throw Win32Error("GetExitCodeProcess");

    public void Dispose()
    {
        Disconnect();
        process.Dispose();
    }

    private static Win32Exception Win32Error(string operation)
    {
        int error = Marshal.GetLastWin32Error();
        return new Win32Exception(error, $"{operation}: Win32 {error} ({new Win32Exception(error).Message})");
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int Size;
        public IntPtr Reserved, Desktop, Title;
        public uint X, Y, Width, Height, XChars, YChars, FillAttribute, Flags;
        public ushort ShowWindow, ReservedSize;
        public IntPtr ReservedData, StandardInput, StandardOutput, StandardError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo Info;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public uint Pid, ThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr list, int count, int flags, ref nuint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr list, uint flags, nuint attribute, IntPtr value, nuint size,
        IntPtr previous, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr list);

    [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode,
        ExactSpelling = true, SetLastError = true)]
    private static extern bool CreateProcess(
        string executable, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup,
        out ProcessInformation child);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);
}
