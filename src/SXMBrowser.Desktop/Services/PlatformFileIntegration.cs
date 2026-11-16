using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;

namespace SXMBrowser.Desktop.Services;

public interface IPlatformFileService
{
    void MoveFilesToRecycleBin(IReadOnlyList<string> fullPaths);
    void RevealInFileExplorer(string fullPath);
}

public sealed class PlatformFileIntegration : IPlatformFileService
{
    private const uint FoDelete = 0x0003;
    private const ushort FofSilent = 0x0004;
    private const ushort FofNoConfirmation = 0x0010;
    private const ushort FofAllowUndo = 0x0040;
    private const ushort FofNoErrorUi = 0x0400;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCTW
    {
        public nint hwnd;
        public uint wFunc;
        public nint pFrom;
        public nint pTo;
        public ushort fFlags;
        [MarshalAs(UnmanagedType.Bool)]
        public bool fAnyOperationsAborted;
        public nint hNameMappings;
        public nint lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW lpFileOp);

    public void MoveFilesToRecycleBin(IReadOnlyList<string> fullPaths)
    {
        if (fullPaths.Count == 0) return;

        string[] normalized = fullPaths
            .Select(Path.GetFullPath)
            .Distinct(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal)
            .ToArray();

        foreach (string path in normalized)
        {
            if (!File.Exists(path) && !Directory.Exists(path))
            {
                throw new FileNotFoundException($"The file no longer exists: {path}", path);
            }
        }

        if (OperatingSystem.IsWindows())
        {
            MoveToWindowsRecycleBin(normalized);
            return;
        }

        if (OperatingSystem.IsMacOS())
        {
            MoveToMacTrash(normalized);
            return;
        }

        throw new PlatformNotSupportedException("Safe Recycle Bin / Trash deletion is only supported on Windows and macOS.");
    }

    public void RevealInFileExplorer(string fullPath)
    {
        string path = Path.GetFullPath(fullPath);

        if (OperatingSystem.IsWindows())
        {
            string arguments = File.Exists(path)
                ? $"/select,\"{path}\""
                : $"\"{path}\"";
            Process.Start(new ProcessStartInfo("explorer.exe", arguments)
            {
                UseShellExecute = false
            });
            return;
        }

        if (OperatingSystem.IsMacOS())
        {
            string arguments = File.Exists(path)
                ? $"-R \"{path}\""
                : $"\"{path}\"";
            Process.Start(new ProcessStartInfo("/usr/bin/open", arguments)
            {
                UseShellExecute = false
            });
        }
    }

    private static void MoveToWindowsRecycleBin(string[] paths)
    {
        string doubleNullTerminated = string.Join('\0', paths) + "\0\0";
        char[] chars = doubleNullTerminated.ToCharArray();
        int byteCount = chars.Length * sizeof(char);
        nint pFrom = Marshal.AllocHGlobal(byteCount);
        try
        {
            Marshal.Copy(chars, 0, pFrom, chars.Length);
            var op = new SHFILEOPSTRUCTW
            {
                hwnd = 0,
                wFunc = FoDelete,
                pFrom = pFrom,
                pTo = 0,
                fFlags = (ushort)(FofAllowUndo | FofNoConfirmation | FofSilent | FofNoErrorUi),
                fAnyOperationsAborted = false,
                hNameMappings = 0,
                lpszProgressTitle = 0
            };

            int result = SHFileOperationW(ref op);
            if (result != 0 || op.fAnyOperationsAborted)
            {
                throw new IOException($"Windows Recycle Bin operation failed (code 0x{result:X}).");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pFrom);
        }
    }

    private static void MoveToMacTrash(string[] paths)
    {
        string trashDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".Trash");
        Directory.CreateDirectory(trashDir);

        foreach (string src in paths)
        {
            string name = Path.GetFileName(src);
            string dest = Path.Combine(trashDir, name);
            if (File.Exists(dest) || Directory.Exists(dest))
            {
                string stem = Path.GetFileNameWithoutExtension(name);
                string ext = Path.GetExtension(name);
                dest = Path.Combine(trashDir, $"{stem} {DateTime.Now:HHmmss}-{Guid.NewGuid():N[..6]}{ext}");
            }
            if (Directory.Exists(src))
            {
                Directory.Move(src, dest);
            }
            else
            {
                File.Move(src, dest);
            }
        }
    }
}
