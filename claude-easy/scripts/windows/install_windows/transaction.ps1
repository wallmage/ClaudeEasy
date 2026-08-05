function Protect-BackupAcl([string]$Path) {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }

    $security = Get-Acl -LiteralPath $Path
    $security.SetAccessRuleProtection($true, $false)
    @($security.Access) | Where-Object { -not $_.IsInherited } | ForEach-Object {
        $security.RemoveAccessRuleSpecific($_)
    } | Out-Null
    $sidValues = @(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        "S-1-5-18",
        "S-1-5-32-544"
    ) | Select-Object -Unique
    foreach ($sidValue in $sidValues) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $security.AddAccessRule($rule) | Out-Null
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function ConvertTo-NormalizedWindowsPath([string]$Path) {
    $candidate = $Path
    if ($candidate.StartsWith("\\?\UNC\", [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = "\\" + $candidate.Substring(8)
    } elseif ($candidate.StartsWith("\\?\", [StringComparison]::OrdinalIgnoreCase)) {
        $candidate = $candidate.Substring(4)
    }
    $absolute = [System.IO.Path]::GetFullPath($candidate)
    return $absolute.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Resolve-ClashVergeAppHome {
    $existing = @()
    foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA)) {
        if ([string]::IsNullOrWhiteSpace([string]$base)) { continue }
        $candidate = Join-Path $base "io.github.clash-verge-rev.clash-verge-rev"
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $normalized = ConvertTo-NormalizedWindowsPath $candidate
            if ($normalized -notin $existing) { $existing += $normalized }
        }
    }
    if ($existing.Count -gt 1) {
        throw "Clash Verge Rev 配置目录不唯一；请从客户端当前目录明确提供 -AppHome。"
    }
    if ($existing.Count -eq 1) { return $existing[0] }
    return ""
}

function Get-AppHomeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace([string]$script:ClaudeEasyMutationRoot)) {
        throw "当前操作没有绑定 Clash Verge Rev 配置目录。"
    }
    $root = ConvertTo-NormalizedWindowsPath $script:ClaudeEasyMutationRoot
    $absolute = ConvertTo-NormalizedWindowsPath $Path
    if ([string]::Equals($absolute, $root, [StringComparison]::OrdinalIgnoreCase)) {
        return "."
    }
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $absolute.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "事务目标超出 Clash Verge Rev 配置目录。"
    }
    return $absolute.Substring($prefix.Length).Replace(
        [System.IO.Path]::AltDirectorySeparatorChar,
        [System.IO.Path]::DirectorySeparatorChar
    )
}

function Enter-AppHomeMutationLock([string]$AppHome) {
    $canonical = ConvertTo-NormalizedWindowsPath $AppHome
    Assert-NoReparsePointPath $canonical "Clash Verge Rev 配置目录"
    Initialize-VerifiedFileNative
    $rootHandle = $null
    $lockStream = $null
    try {
        try {
            $rootHandle = [ClaudeEasy.VerifiedDeleteNative]::OpenDirectory($canonical)
            if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($rootHandle)) {
                throw "Clash Verge Rev 配置目录不能是符号链接、目录联接或其他重解析点。"
            }
            $lockHandle = [ClaudeEasy.VerifiedDeleteNative]::OpenLockFile(
                (Join-Path $canonical ".claude-easy.lock")
            )
            if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($lockHandle) -or
                [ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($lockHandle) -ne 1) {
                $lockHandle.Dispose()
                throw "ClaudeEasy 锁文件不能是链接。"
            }
            $lockStream = New-Object System.IO.FileStream($lockHandle, [System.IO.FileAccess]::ReadWrite)
        } catch [System.ComponentModel.Win32Exception] {
            throw "同一配置目录已有 ClaudeEasy 操作正在进行，请稍后重试。"
        }

        $script:ClaudeEasyMutationRoot = $canonical
        $script:ClaudeEasyTransactionJournalPath = Join-Path $canonical ".claude-easy-transaction.json"
        $script:ClaudeEasyTransactionPreparationPath = Join-Path $canonical ".claude-easy-transaction-preparation.json"
        $recoveredTransaction = Test-Path -LiteralPath $script:ClaudeEasyTransactionJournalPath -PathType Leaf
        $recoveredPreparation = Test-Path -LiteralPath $script:ClaudeEasyTransactionPreparationPath -PathType Leaf
        Repair-InterruptedFileTransaction
        Repair-InterruptedFilePreparation
        return [pscustomobject]@{
            Root = $canonical
            RootHandle = $rootHandle
            LockStream = $lockStream
            RecoveredTransaction = ($recoveredTransaction -or $recoveredPreparation)
        }
    } catch {
        if ($null -ne $lockStream) { $lockStream.Dispose() }
        if ($null -ne $rootHandle) { $rootHandle.Dispose() }
        $script:ClaudeEasyMutationRoot = $null
        $script:ClaudeEasyTransactionJournalPath = $null
        $script:ClaudeEasyTransactionPreparationPath = $null
        throw
    }
}

function Exit-AppHomeMutationLock([object]$Lock) {
    if ($null -eq $Lock) { return }
    try {
        if ($null -ne $Lock.LockStream) { $Lock.LockStream.Dispose() }
    } finally {
        if ($null -ne $Lock.RootHandle) { $Lock.RootHandle.Dispose() }
        if ([string]::Equals(
            [string]$script:ClaudeEasyMutationRoot,
            [string]$Lock.Root,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $script:ClaudeEasyMutationRoot = $null
            $script:ClaudeEasyTransactionJournalPath = $null
            $script:ClaudeEasyTransactionPreparationPath = $null
        }
    }
}

function Get-PathKey([string]$Path) {
    $identity = if ([string]::IsNullOrWhiteSpace([string]$script:ClaudeEasyMutationRoot)) {
        (ConvertTo-NormalizedWindowsPath $Path).ToUpperInvariant()
    } else {
        (Get-AppHomeRelativePath $Path).ToUpperInvariant()
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return (($sha.ComputeHash($bytes, 0, $bytes.Length) | ForEach-Object { $_.ToString("x2") }) -join '').Substring(0, 16)
    } finally {
        $sha.Dispose()
    }
}

function Assert-NoReparsePointPath([string]$Path, [string]$Label) {
    $current = [System.IO.Path]::GetFullPath($Path)
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    while (-not [string]::IsNullOrWhiteSpace($current) -and $visited.Add($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label 不能经过符号链接、目录联接或其他重解析点：$current"
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent, $current, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent
    }
}

function Backup-Versioned(
    [string]$Path,
    [string]$BackupRoot,
    [string]$Reason = "prewrite",
    [switch]$WithMetadata,
    [byte[]]$SourceBytes = $null,
    [switch]$UseSourceBytes
) {
    Assert-NoReparsePointPath $Path "备份来源"
    Assert-NoReparsePointPath $BackupRoot "备份目录"
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if ($Reason -notmatch '^[a-z][a-z0-9-]{0,31}$') { throw "备份原因无效。" }
    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }
    $key = Get-PathKey $Path
    $basename = Split-Path -Leaf $Path
    $stampTime = Get-Date
    $destination = $null
    for ($attempt = 0; $attempt -lt 100; $attempt++) {
        $stamp = $stampTime.AddTicks($attempt).ToString(
            "yyyy-MM-dd_HH-mm-ss.fffffffzzz",
            [System.Globalization.CultureInfo]::InvariantCulture
        ).Replace(":", "")
        $candidate = Join-Path $BackupRoot ("$stamp--$Reason--$key--$basename.backup")
        if (-not (Test-Path -LiteralPath $candidate)) {
            $destination = $candidate
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($destination)) { throw "无法生成唯一的备份编号。" }
    $temporary = Join-Path $BackupRoot (
        ".claude-easy-backup-" + [System.Guid]::NewGuid().ToString("N") + ".tmp"
    )
    $sourceStream = $null
    $backupStream = $null
    $created = $false
    $createdBytes = $null
    $failure = $null
    try {
        $backupStream = New-PrivateFileStream $temporary
        $created = $true
        if ($UseSourceBytes) {
            if ($null -eq $SourceBytes) { $SourceBytes = [byte[]]@() }
            $backupStream.Write($SourceBytes, 0, $SourceBytes.Length)
        } else {
            $sourceStream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $sourceStream.CopyTo($backupStream)
        }
        $backupStream.Flush($true)
        $createdBytes = Get-StreamBytes $backupStream
    } catch {
        $failure = $_
    } finally {
        if ($created -and $null -ne $backupStream -and $null -eq $createdBytes) {
            try { $createdBytes = Get-StreamBytes $backupStream } catch { }
        }
        if ($null -ne $backupStream) { $backupStream.Dispose() }
        if ($null -ne $sourceStream) { $sourceStream.Dispose() }
    }
    if ($null -ne $failure) {
        if ($created -and $null -ne $createdBytes) {
            Remove-VerifiedOwnedFile $temporary $createdBytes
        }
        throw $failure
    }
    try {
        [System.IO.File]::Move($temporary, $destination)
    } catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-VerifiedOwnedFile $temporary $createdBytes
        }
        throw
    }
    if ($WithMetadata) {
        return [pscustomobject]@{
            Path = $destination
            Sha256 = Get-BytesSha256 $createdBytes
        }
    }
    return $destination
}

function Backup-InitialOnce(
    [string]$Path,
    [string]$BackupRoot,
    [byte[]]$SourceBytes = $null,
    [switch]$UseSourceBytes
) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $key = Get-PathKey $Path
    $basename = Split-Path -Leaf $Path
    if (Test-Path -LiteralPath $BackupRoot -PathType Container) {
        $existing = Get-ChildItem -LiteralPath $BackupRoot -File | Where-Object {
            $_.Name -like "*--initial--$key--$basename.backup"
        } | Select-Object -First 1
        if ($null -ne $existing) { return }
    }
    return (Backup-Versioned `
        $Path `
        $BackupRoot `
        "initial" `
        -SourceBytes $SourceBytes `
        -UseSourceBytes:$UseSourceBytes)
}

function Write-BytesAtomic([string]$Path, [byte[]]$Bytes) {
    $snapshot = Get-OptionalFileSnapshot $Path "写入目标"
    Invoke-VerifiedFileTransaction @(
        [pscustomobject]@{
            Path = $Path
            Bytes = $Bytes
            Existed = [bool]$snapshot.Exists
            OriginalBytes = $snapshot.Bytes
            OriginalIdentity = $snapshot.Identity
        }
    )
}

function ConvertTo-Utf8Bytes([string]$Content) {
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($Content)
}

function Write-Utf8Atomic([string]$Path, [string]$Content) {
    Write-BytesAtomic $Path (ConvertTo-Utf8Bytes $Content)
}


function Get-BytesSha256([byte[]]$Bytes) {
    # PowerShell binds an empty byte array as $null; empty input must still hash.
    if ($null -eq $Bytes) { $Bytes = [byte[]]@() }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes, 0, $Bytes.Length))).Replace("-", "").ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
    return (Get-BytesSha256 ([System.IO.File]::ReadAllBytes($Path)))
}

function Get-StreamBytes([System.IO.FileStream]$Stream) {
    $Stream.Position = 0
    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $memory.Dispose()
    }
}

function Get-OptionalFileSnapshot([string]$Path, [string]$Label) {
    Assert-NoReparsePointPath $Path $Label
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            Path = $Path
            Bytes = $null
            Identity = $null
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label 路径不是文件。"
    }
    Initialize-VerifiedFileNative
    $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $Path))
    $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($Path, $false, $false)
    $stream = $null
    try {
        if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle)) {
            throw "$Label 不能是符号链接或其他重解析点。"
        }
        if ([ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
            throw "$Label 不能有硬链接别名。"
        }
        $identity = [ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle)
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        return [pscustomobject]@{
            Exists = $true
            Path = $Path
            Bytes = Get-StreamBytes $stream
            Identity = $identity
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } else {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Remove-VerifiedOwnedFile(
    [string]$Path,
    [byte[]]$ExpectedBytes,
    [string]$ExpectedIdentity = "",
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $snapshot = Get-OptionalFileSnapshot $Path "待删除文件"
    if ((Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $ExpectedBytes) -or
        (-not [string]::IsNullOrWhiteSpace($ExpectedIdentity) -and $snapshot.Identity -cne $ExpectedIdentity)) {
        throw "待删除文件在验证后发生变化。"
    }
    Invoke-VerifiedWriteDeleteTransaction @() @(
        [pscustomobject]@{
            Path = $Path
            Existed = $true
            OriginalBytes = $snapshot.Bytes
            OriginalIdentity = $snapshot.Identity
        }
    ) -InterruptedRecoveryPolicy $InterruptedRecoveryPolicy
}

function Write-LockedStreamBytes(
    [System.IO.FileStream]$Stream,
    [byte[]]$Replacement,
    [byte[]]$Original
) {
    try {
        $Stream.Position = 0
        $Stream.SetLength(0)
        $Stream.Write($Replacement, 0, $Replacement.Length)
        $Stream.SetLength($Replacement.Length)
        $Stream.Flush($true)
    } catch {
        $writeError = $_
        try {
            $Stream.Position = 0
            $Stream.SetLength(0)
            $Stream.Write($Original, 0, $Original.Length)
            $Stream.SetLength($Original.Length)
            $Stream.Flush($true)
        } catch {
            throw "写入失败，且原内容恢复失败：$($_.Exception.Message)"
        }
        throw $writeError
    }
}

function Initialize-VerifiedFileNative {
    if ($null -ne ("ClaudeEasy.VerifiedDeleteNative" -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;

namespace ClaudeEasy
{
    public static class VerifiedDeleteNative
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint DeleteAccess = 0x00010000;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint OpenAlways = 4;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint WriteThrough = 0x80000000;
        private const uint OpenReparsePoint = 0x00200000;
        private const uint BackupSemantics = 0x02000000;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const int FileDispositionInfo = 4;
        private const int FileAttributeTagInfo = 9;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileDispositionInformation
        {
            public byte DeleteFile;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes
        {
            public int Length;
            public IntPtr SecurityDescriptor;
            public int InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct FileAttributeTagInformation
        {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformation
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(
            SafeFileHandle file,
            int informationClass,
            ref FileDispositionInformation information,
            uint bufferSize
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int informationClass,
            out FileAttributeTagInformation information,
            uint bufferSize
        );

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out ByHandleFileInformation information
        );

        public static SafeFileHandle Open(string path, bool writable, bool createNew)
        {
            uint desiredAccess = GenericRead | DeleteAccess;
            if (writable)
            {
                desiredAccess |= GenericWrite;
            }
            SafeFileHandle handle = CreateFile(
                path,
                desiredAccess,
                0,
                IntPtr.Zero,
                createNew ? CreateNew : OpenExisting,
                OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法独占打开事务目标。");
            }
            return handle;
        }

        public static SafeFileHandle OpenDirectory(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                0,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                BackupSemantics | OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法锁定事务目标目录。");
            }
            return handle;
        }

        public static SafeFileHandle OpenLockFile(string path)
        {
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead | GenericWrite,
                0,
                IntPtr.Zero,
                OpenAlways,
                OpenReparsePoint,
                IntPtr.Zero
            );
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new Win32Exception(error, "无法获取配置目录操作锁。");
            }
            return handle;
        }

        public static SafeFileHandle CreatePrivateFile(string path)
        {
            FileSecurity security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            SecurityIdentifier[] identities = new SecurityIdentifier[]
            {
                WindowsIdentity.GetCurrent().User,
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null)
            };
            foreach (SecurityIdentifier identity in identities)
            {
                security.AddAccessRule(new FileSystemAccessRule(
                    identity,
                    FileSystemRights.FullControl,
                    AccessControlType.Allow
                ));
            }
            byte[] descriptor = security.GetSecurityDescriptorBinaryForm();
            IntPtr descriptorPointer = IntPtr.Zero;
            IntPtr attributesPointer = IntPtr.Zero;
            try
            {
                descriptorPointer = Marshal.AllocHGlobal(descriptor.Length);
                Marshal.Copy(descriptor, 0, descriptorPointer, descriptor.Length);
                SecurityAttributes attributes = new SecurityAttributes();
                attributes.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                attributes.SecurityDescriptor = descriptorPointer;
                attributes.InheritHandle = 0;
                attributesPointer = Marshal.AllocHGlobal(attributes.Length);
                Marshal.StructureToPtr(attributes, attributesPointer, false);

                SafeFileHandle handle = CreateFile(
                    path,
                    GenericRead | GenericWrite | DeleteAccess,
                    0,
                    attributesPointer,
                    CreateNew,
                    WriteThrough | OpenReparsePoint,
                    IntPtr.Zero
                );
                if (handle.IsInvalid)
                {
                    int error = Marshal.GetLastWin32Error();
                    handle.Dispose();
                    throw new Win32Exception(
                        error,
                        "无法创建私有的事务恢复临时文件。"
                    );
                }
                return handle;
            }
            finally
            {
                if (attributesPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(attributesPointer);
                }
                if (descriptorPointer != IntPtr.Zero)
                {
                    Marshal.FreeHGlobal(descriptorPointer);
                }
            }
        }

        public static bool IsReparsePoint(SafeFileHandle handle)
        {
            FileAttributeTagInformation information;
            if (!GetFileInformationByHandleEx(
                handle,
                FileAttributeTagInfo,
                out information,
                (uint)Marshal.SizeOf(typeof(FileAttributeTagInformation))
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取待删除文件属性。");
            }
            return (information.FileAttributes & FileAttributeReparsePoint) != 0;
        }

        public static uint GetLinkCount(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取事务目标的文件身份。");
            }
            return information.NumberOfLinks;
        }

        public static string GetIdentity(SafeFileHandle handle)
        {
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法读取事务目标的文件身份。");
            }
            return information.VolumeSerialNumber.ToString("x8") + ":" +
                information.FileIndexHigh.ToString("x8") +
                information.FileIndexLow.ToString("x8");
        }

        public static void SetDeleteDisposition(SafeFileHandle handle, bool deleteFile)
        {
            FileDispositionInformation information = new FileDispositionInformation();
            information.DeleteFile = deleteFile ? (byte)1 : (byte)0;
            if (!SetFileInformationByHandle(
                handle,
                FileDispositionInfo,
                ref information,
                (uint)Marshal.SizeOf(typeof(FileDispositionInformation))
            ))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "无法更新已经验证的文件删除状态。");
            }
        }
    }
}
'@
}

function Open-VerifiedDirectoryChain([string]$Directory) {
    Initialize-VerifiedFileNative
    $absolute = ConvertTo-NormalizedWindowsPath $Directory
    $root = [System.IO.Path]::GetPathRoot($absolute)
    if ([string]::IsNullOrWhiteSpace($root)) { throw "事务目标目录无效。" }
    $relative = $absolute.Substring($root.Length)
    $segments = @($relative.Split(
        @([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar),
        [System.StringSplitOptions]::RemoveEmptyEntries
    ))
    $handles = @()
    $current = $root
    try {
        $rootHandle = [ClaudeEasy.VerifiedDeleteNative]::OpenDirectory($current)
        if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($rootHandle)) {
            $rootHandle.Dispose()
            throw "事务目标目录不能经过重解析点：$current"
        }
        $handles += $rootHandle
        foreach ($segment in $segments) {
            $current = Join-Path $current $segment
            if (-not (Test-Path -LiteralPath $current -PathType Container)) {
                New-Item -ItemType Directory -Path $current | Out-Null
            }
            $handle = [ClaudeEasy.VerifiedDeleteNative]::OpenDirectory($current)
            if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle)) {
                $handle.Dispose()
                throw "事务目标目录不能经过重解析点：$current"
            }
            $handles += $handle
        }
        return $handles
    } catch {
        for ($index = $handles.Count - 1; $index -ge 0; $index--) {
            $handles[$index].Dispose()
        }
        throw
    }
}

function Set-VerifiedDeleteDisposition([System.IO.FileStream]$Stream, [bool]$DeleteFile) {
    [ClaudeEasy.VerifiedDeleteNative]::SetDeleteDisposition($Stream.SafeFileHandle, $DeleteFile)
}

function New-PrivateFileStream([string]$Path) {
    Initialize-VerifiedFileNative
    $handle = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::CreatePrivateFile($Path)
        $stream = New-Object System.IO.FileStream(
            $handle,
            [System.IO.FileAccess]::ReadWrite
        )
        $handle = $null
        return $stream
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Write-FileTransactionPreparation(
    [object[]]$Actions,
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    $path = [string]$script:ClaudeEasyTransactionPreparationPath
    $createdActions = @($Actions | Where-Object { $_.CreateNew })
    if ([string]::IsNullOrWhiteSpace($path) -or $createdActions.Count -eq 0) {
        return $null
    }
    if (Test-Path -LiteralPath $path) {
        throw "发现尚未恢复的新建文件准备记录。"
    }
    $relativePaths = @($createdActions | Sort-Object Path | ForEach-Object {
        Get-AppHomeRelativePath ([string]$_.Path)
    })
    $targetPaths = @($Actions | Sort-Object Path | ForEach-Object {
        Get-AppHomeRelativePath ([string]$_.Path)
    })
    $record = [ordered]@{
        Version = 2
        Paths = $relativePaths
        Targets = $targetPaths
        RecoveryPolicy = $InterruptedRecoveryPolicy
    }
    $bytes = ConvertTo-Utf8Bytes (($record | ConvertTo-Json -Depth 3) + "`r`n")
    $temporary = Join-Path $script:ClaudeEasyMutationRoot (
        ".claude-easy-transaction-preparation." + [Guid]::NewGuid().ToString("N") + ".tmp"
    )
    $stream = $null
    $moved = $false
    try {
        $stream = New-PrivateFileStream $temporary
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporary, $path)
        $moved = $true
        return $bytes
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (-not $moved -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Get-ValidatedFileTransactionPaths(
    [object[]]$RelativePaths,
    [string]$Label
) {
    if (@($RelativePaths).Count -eq 0) { throw "$Label 没有目标。" }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $validated = @()
    foreach ($relativeValue in @($RelativePaths)) {
        if (-not ($relativeValue -is [string])) { throw "$Label 路径无效。" }
        $relative = [string]$relativeValue
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative -eq "." -or
            @($relative.Split("\") | Where-Object { $_ -eq ".." }).Count -gt 0) {
            throw "$Label 路径无效。"
        }
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $script:ClaudeEasyMutationRoot $relative))
        if ((Get-AppHomeRelativePath $absolute) -cne $relative.Replace(
            [System.IO.Path]::AltDirectorySeparatorChar,
            [System.IO.Path]::DirectorySeparatorChar
        ) -or -not $paths.Add($absolute)) {
            throw "$Label 路径无效。"
        }
        $validated += $absolute
    }
    return $validated
}

function Get-InterruptedRecoveryPolicy([object]$Record) {
    if ([long]$Record.Version -eq 1) { return "client_stopped" }
    $policy = $Record.RecoveryPolicy
    if (-not ($policy -is [string]) -or
        [string]$policy -notin @("client_stopped", "safe_update_running_client")) {
        throw "事务恢复权限无效。"
    }
    return [string]$policy
}

function Get-ValidatedFileTransactionPreparation([object]$Record) {
    if ($null -eq $Record) { throw "新建文件准备记录无效。" }
    $properties = @($Record.PSObject.Properties.Name | Sort-Object)
    $numericVersion = $Record.Version -is [int] -or $Record.Version -is [long]
    $version = if ($numericVersion) { [long]$Record.Version } else { 0 }
    $expectedProperties = if ($version -eq 1) {
        "Paths,Version"
    } elseif ($version -eq 2) {
        "Paths,RecoveryPolicy,Targets,Version"
    } else {
        ""
    }
    if (-not $numericVersion -or
        [string]::IsNullOrWhiteSpace($expectedProperties) -or
        ($properties -join ",") -cne $expectedProperties) {
        throw "新建文件准备记录无效。"
    }
    Get-InterruptedRecoveryPolicy $Record | Out-Null
    $validated = @(
        Get-ValidatedFileTransactionPaths @($Record.Paths) "新建文件准备记录"
    )
    if ($version -eq 2) {
        $targets = @(
            Get-ValidatedFileTransactionPaths @($Record.Targets) "事务恢复目标"
        )
        foreach ($path in $validated) {
            if ($path -notin $targets) { throw "新建文件准备记录目标不完整。" }
        }
    }
    return $validated
}

function Get-ValidatedFileTransactionPreparationTargets([object]$Record) {
    if ([long]$Record.Version -eq 1) {
        return @(
            Get-ValidatedFileTransactionPaths @($Record.Paths) "新建文件准备记录"
        )
    }
    return @(
        Get-ValidatedFileTransactionPaths @($Record.Targets) "事务恢复目标"
    )
}

function Remove-FileTransactionPreparation([byte[]]$ExpectedBytes) {
    $path = [string]$script:ClaudeEasyTransactionPreparationPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "新建文件准备记录"
    if (-not $snapshot.Exists) { return }
    if ((Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $ExpectedBytes)) {
        throw "新建文件准备记录在操作期间发生变化。"
    }
    $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $path))
    $handle = $null
    $stream = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($path, $false, $false)
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        if ([ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle) -cne $snapshot.Identity -or
            (Get-BytesSha256 (Get-StreamBytes $stream)) -ne (Get-BytesSha256 $ExpectedBytes)) {
            throw "新建文件准备记录在操作期间发生变化。"
        }
        Set-VerifiedDeleteDisposition $stream $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Test-SafeUpdateRunningRecoveryTargets([string[]]$Paths) {
    $manifestPath = ConvertTo-NormalizedWindowsPath (
        Join-Path $script:ClaudeEasyMutationRoot "claude-easy-safe-update.json"
    )
    $profilesRoot = ConvertTo-NormalizedWindowsPath (
        Join-Path $script:ClaudeEasyMutationRoot "profiles"
    )
    $manifestSeen = $false
    foreach ($path in $Paths) {
        $targetPath = ConvertTo-NormalizedWindowsPath $path
        if ([string]::Equals(
            $targetPath,
            $manifestPath,
            [StringComparison]::OrdinalIgnoreCase
        )) {
            $manifestSeen = $true
            continue
        }
        $parent = ConvertTo-NormalizedWindowsPath (
            [System.IO.Path]::GetDirectoryName($targetPath)
        )
        $extension = [System.IO.Path]::GetExtension($targetPath)
        if (-not [string]::Equals(
            $parent,
            $profilesRoot,
            [StringComparison]::OrdinalIgnoreCase
        ) -or $extension -notin @(".yaml", ".yml")) {
            return $false
        }
    }
    return $manifestSeen
}

function Test-InterruptedRecoveryRequiresStoppedClient(
    [string]$InterruptedRecoveryPolicy,
    [string[]]$Paths
) {
    if ($InterruptedRecoveryPolicy -eq "client_stopped") { return $true }
    if ($InterruptedRecoveryPolicy -eq "safe_update_running_client" -and
        (Test-SafeUpdateRunningRecoveryTargets $Paths)) {
        return $false
    }
    throw "事务恢复权限与目标不匹配。"
}

function Test-InterruptedRecoveryCommitCondition([scriptblock]$PreCommitCondition) {
    if ($null -eq $PreCommitCondition) { return $true }
    $results = @(& $PreCommitCondition)
    if ($results.Count -ne 1 -or -not ($results[0] -is [bool])) {
        throw "中断事务恢复提交条件必须只返回一个布尔值。"
    }
    return [bool]$results[0]
}

function Repair-InterruptedFilePreparation {
    $path = [string]$script:ClaudeEasyTransactionPreparationPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "新建文件准备记录"
    if (-not $snapshot.Exists) { return }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes)
        if ([regex]::Matches($text, '(?i)"Version"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"Paths"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"Targets"\s*:').Count -gt 1 -or
            [regex]::Matches($text, '(?i)"RecoveryPolicy"\s*:').Count -gt 1) {
            throw "字段重复或缺失。"
        }
        $record = $text | ConvertFrom-Json
        $paths = @(Get-ValidatedFileTransactionPreparation $record)
        $recoveryTargets = @(
            Get-ValidatedFileTransactionPreparationTargets $record
        )
        $recoveryPolicy = Get-InterruptedRecoveryPolicy $record
    } catch {
        throw "新建文件准备记录损坏，无法安全恢复。"
    }
    $targets = @()
    foreach ($targetPath in $paths) {
        $target = Get-OptionalFileSnapshot $targetPath "中断事务新建目标"
        if (-not $target.Exists) { continue }
        if ($target.Bytes.Length -ne 0) {
            throw "中断事务新建目标包含无法自动合并的内容：$targetPath"
        }
        $targets += $target
    }
    $preCommitCondition = $null
    if (Test-InterruptedRecoveryRequiresStoppedClient `
        $recoveryPolicy $recoveryTargets) {
        if (Test-ClashVergeRunning) {
            throw "客户端保持运行；中断的客户端敏感事务等待恢复。"
        }
        $preCommitCondition = { -not (Test-ClashVergeRunning) }
    }
    Initialize-VerifiedFileNative
    $opened = @()
    $directoryHandles = @()
    $operationFailure = $null
    $preCommitRejected = $false
    $finalizeRejected = $false
    $deleteMarked = $false
    foreach ($target in $targets) {
        $targetPath = [string]$target.Path
        $handle = $null
        $stream = $null
        try {
            $directoryHandles += @(
                Open-VerifiedDirectoryChain (Split-Path -Parent $targetPath)
            )
            $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($targetPath, $false, $false)
            $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
            if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle) -or
                [ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1 -or
                [ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle) -cne $target.Identity -or
                (Get-StreamBytes $stream).Length -ne 0) {
                throw "中断事务新建目标在恢复前再次发生变化：$targetPath"
            }
            $opened += [pscustomobject]@{
                Target = $target
                Stream = $stream
            }
        } catch {
            if ($null -ne $stream) { $stream.Dispose() } elseif ($null -ne $handle) { $handle.Dispose() }
            $operationFailure = $_
            break
        }
    }
    if ($null -eq $operationFailure) {
        try {
            $preCommitRejected = -not (
                Test-InterruptedRecoveryCommitCondition $preCommitCondition
            )
            if (-not $preCommitRejected) {
                foreach ($entry in $opened) {
                    Set-VerifiedDeleteDisposition $entry.Stream $true
                }
                $deleteMarked = $true
                $finalizeRejected = -not (
                    Test-InterruptedRecoveryCommitCondition $preCommitCondition
                )
                if ($finalizeRejected) {
                    foreach ($entry in $opened) {
                        Set-VerifiedDeleteDisposition $entry.Stream $false
                    }
                    $deleteMarked = $false
                }
            }
        } catch {
            $operationFailure = $_
            if ($deleteMarked) {
                try {
                    foreach ($entry in $opened) {
                        Set-VerifiedDeleteDisposition $entry.Stream $false
                    }
                    $deleteMarked = $false
                } catch {
                    $operationFailure = $_
                }
            }
        }
    }
    for ($index = $opened.Count - 1; $index -ge 0; $index--) {
        try {
            $opened[$index].Stream.Dispose()
        } catch {
            if ($null -eq $operationFailure) { $operationFailure = $_ }
        }
    }
    for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
        try {
            $directoryHandles[$index].Dispose()
        } catch {
            if ($null -eq $operationFailure) { $operationFailure = $_ }
        }
    }
    if ($null -ne $operationFailure) { throw $operationFailure }
    if ($preCommitRejected -or $finalizeRejected) {
        throw "客户端保持运行；中断的客户端敏感事务等待恢复。"
    }
    Remove-FileTransactionPreparation $snapshot.Bytes
}

function Write-FileTransactionJournal(
    [object[]]$Entries,
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    if ([string]::IsNullOrWhiteSpace([string]$script:ClaudeEasyTransactionJournalPath) -or
        @($Entries).Count -eq 0) {
        return $null
    }
    if (Test-Path -LiteralPath $script:ClaudeEasyTransactionJournalPath) {
        throw "发现尚未恢复的文件事务记录。"
    }
    $journalActions = @()
    foreach ($entry in $Entries) {
        [byte[]]$originalBytes = @()
        if ($null -ne $entry.Original) { $originalBytes = [byte[]]$entry.Original }
        $journalActions += [ordered]@{
            Action = [string]$entry.Action
            Path = Get-AppHomeRelativePath ([string]$entry.Target.Path)
            Existed = (-not [bool]$entry.Created)
            Identity = [ClaudeEasy.VerifiedDeleteNative]::GetIdentity($entry.Stream.SafeFileHandle)
            OriginalBase64 = [Convert]::ToBase64String($originalBytes)
            ReplacementBase64 = if ($entry.Action -eq "write") {
                [Convert]::ToBase64String([byte[]]$entry.Target.Bytes)
            } else {
                ""
            }
        }
    }
    $journal = [ordered]@{
        Version = 2
        Actions = $journalActions
        RecoveryPolicy = $InterruptedRecoveryPolicy
    }
    $bytes = ConvertTo-Utf8Bytes (($journal | ConvertTo-Json -Depth 5) + "`r`n")
    $temporary = Join-Path $script:ClaudeEasyMutationRoot (
        ".claude-easy-transaction." + [Guid]::NewGuid().ToString("N") + ".tmp"
    )
    $stream = $null
    $moved = $false
    try {
        $stream = New-PrivateFileStream $temporary
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null
        [System.IO.File]::Move($temporary, $script:ClaudeEasyTransactionJournalPath)
        $moved = $true
        return $bytes
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if (-not $moved -and (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            [System.IO.File]::Delete($temporary)
        }
    }
}

function Remove-FileTransactionJournal([byte[]]$ExpectedBytes) {
    $path = [string]$script:ClaudeEasyTransactionJournalPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "文件事务记录"
    if (-not $snapshot.Exists) { return }
    if ((Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $ExpectedBytes)) {
        throw "文件事务记录在操作期间发生变化。"
    }
    $directoryHandles = @(Open-VerifiedDirectoryChain (Split-Path -Parent $path))
    $handle = $null
    $stream = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::Open($path, $false, $false)
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        if ([ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle) -cne $snapshot.Identity -or
            (Get-BytesSha256 (Get-StreamBytes $stream)) -ne (Get-BytesSha256 $ExpectedBytes)) {
            throw "文件事务记录在操作期间发生变化。"
        }
        Set-VerifiedDeleteDisposition $stream $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Get-ValidatedFileTransactionJournal([object]$Journal) {
    if ($null -eq $Journal) { throw "文件事务记录无效。" }
    $properties = @($Journal.PSObject.Properties.Name | Sort-Object)
    $numericVersion = $Journal.Version -is [int] -or $Journal.Version -is [long]
    $version = if ($numericVersion) { [long]$Journal.Version } else { 0 }
    $expectedProperties = if ($version -eq 1) {
        "Actions,Version"
    } elseif ($version -eq 2) {
        "Actions,RecoveryPolicy,Version"
    } else {
        ""
    }
    if (-not $numericVersion -or
        [string]::IsNullOrWhiteSpace($expectedProperties) -or
        ($properties -join ",") -cne $expectedProperties) {
        throw "文件事务记录无效。"
    }
    Get-InterruptedRecoveryPolicy $Journal | Out-Null
    $actions = @($Journal.Actions)
    if ($actions.Count -eq 0) { throw "文件事务记录没有操作项。" }
    $paths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $validated = @()
    foreach ($action in $actions) {
        $actionProperties = @($action.PSObject.Properties.Name | Sort-Object)
        if (($actionProperties -join ",") -cne "Action,Existed,Identity,OriginalBase64,Path,ReplacementBase64" -or
            [string]$action.Action -notin @("write", "delete") -or
            -not ($action.Existed -is [bool]) -or
            -not ($action.Identity -is [string]) -or
            [string]::IsNullOrWhiteSpace([string]$action.Identity) -or
            -not ($action.OriginalBase64 -is [string]) -or
            -not ($action.ReplacementBase64 -is [string])) {
            throw "文件事务记录操作项无效。"
        }
        $relative = [string]$action.Path
        if ([string]::IsNullOrWhiteSpace($relative) -or
            [System.IO.Path]::IsPathRooted($relative) -or
            $relative -eq "." -or
            @($relative.Split("\") | Where-Object { $_ -eq ".." }).Count -gt 0) {
            throw "文件事务记录包含无效路径。"
        }
        $absolute = [System.IO.Path]::GetFullPath((Join-Path $script:ClaudeEasyMutationRoot $relative))
        if ((Get-AppHomeRelativePath $absolute) -cne $relative.Replace(
            [System.IO.Path]::AltDirectorySeparatorChar,
            [System.IO.Path]::DirectorySeparatorChar
        )) {
            throw "文件事务记录路径不规范。"
        }
        if (-not $paths.Add($absolute)) { throw "文件事务记录包含重复路径。" }
        try {
            $original = [Convert]::FromBase64String([string]$action.OriginalBase64)
            $replacement = [Convert]::FromBase64String([string]$action.ReplacementBase64)
        } catch {
            throw "文件事务记录包含无效 Base64。"
        }
        if ([Convert]::ToBase64String($original) -cne [string]$action.OriginalBase64 -or
            [Convert]::ToBase64String($replacement) -cne [string]$action.ReplacementBase64 -or
            ([string]$action.Action -eq "delete" -and
                (-not [bool]$action.Existed -or $replacement.Length -ne 0)) -or
            ([string]$action.Action -eq "write" -and
                -not [bool]$action.Existed -and $original.Length -ne 0)) {
            throw "文件事务记录内容不规范。"
        }
        $validated += [pscustomobject]@{
            Action = [string]$action.Action
            Path = $absolute
            Existed = [bool]$action.Existed
            Identity = [string]$action.Identity
            Original = $original
            Replacement = $replacement
        }
    }
    return $validated
}

function Get-InterruptedTransactionRecoveryPlan([object[]]$Actions) {
    $plan = @()
    foreach ($action in $Actions) {
        $snapshot = Get-OptionalFileSnapshot $action.Path "中断事务目标"
        $currentHash = if ($snapshot.Exists) { Get-BytesSha256 $snapshot.Bytes } else { "" }
        $originalHash = Get-BytesSha256 $action.Original
        $replacementHash = Get-BytesSha256 $action.Replacement
        $isInterruptedOriginal = $snapshot.Exists -and
            $snapshot.Bytes.Length -le $action.Original.Length
        if ($isInterruptedOriginal) {
            for ($index = 0; $index -lt $snapshot.Bytes.Length; $index++) {
                if ($snapshot.Bytes[$index] -ne $action.Original[$index]) {
                    $isInterruptedOriginal = $false
                    break
                }
            }
        }
        $isInterruptedReplacement = $action.Action -eq "write" -and
            $snapshot.Exists -and
            $snapshot.Bytes.Length -lt $action.Replacement.Length
        if ($isInterruptedReplacement) {
            for ($index = 0; $index -lt $snapshot.Bytes.Length; $index++) {
                if ($snapshot.Bytes[$index] -ne $action.Replacement[$index]) {
                    $isInterruptedReplacement = $false
                    break
                }
            }
        }
        $differentIdentityIsRestoredOriginal = $action.Action -eq "write" -and
            $action.Existed -and $snapshot.Exists -and $currentHash -eq $originalHash
        if ($snapshot.Exists -and $snapshot.Identity -cne $action.Identity -and
            -not $differentIdentityIsRestoredOriginal -and
            ($action.Action -ne "delete" -or $currentHash -ne $originalHash)) {
            throw "中断事务目标已被同内容的其他文件替换：$($action.Path)"
        }
        if ($action.Action -eq "write" -and $action.Existed) {
            if (-not $snapshot.Exists -or
                ($currentHash -notin @($originalHash, $replacementHash) -and
                    -not $isInterruptedReplacement -and -not $isInterruptedOriginal)) {
                throw "中断事务目标有无法自动合并的新改动：$($action.Path)"
            }
            if ($currentHash -ne $originalHash) {
                $plan += [pscustomobject]@{ Operation = "write"; Action = $action; Snapshot = $snapshot }
            } else {
                $plan += [pscustomobject]@{ Operation = "verify"; Action = $action; Snapshot = $snapshot }
            }
        } elseif ($action.Action -eq "write") {
            if ($snapshot.Exists -and
                $currentHash -ne $replacementHash -and -not $isInterruptedReplacement) {
                throw "中断事务新建目标有无法自动合并的新改动：$($action.Path)"
            }
            if ($snapshot.Exists) {
                $plan += [pscustomobject]@{ Operation = "delete"; Action = $action; Snapshot = $snapshot }
            } else {
                $plan += [pscustomobject]@{ Operation = "verify_absent"; Action = $action; Snapshot = $snapshot }
            }
        } else {
            if ($snapshot.Exists -and $currentHash -ne $originalHash -and -not $isInterruptedOriginal) {
                throw "中断事务删除目标有无法自动合并的新改动：$($action.Path)"
            }
            if (-not $snapshot.Exists) {
                $plan += [pscustomobject]@{ Operation = "create"; Action = $action; Snapshot = $snapshot }
            } elseif ($currentHash -ne $originalHash) {
                $plan += [pscustomobject]@{ Operation = "write"; Action = $action; Snapshot = $snapshot }
            } else {
                $plan += [pscustomobject]@{ Operation = "verify"; Action = $action; Snapshot = $snapshot }
            }
        }
    }
    return $plan
}

function New-InterruptedRecoveryTemporaryFile(
    [string]$TargetPath,
    [byte[]]$Bytes
) {
    $directory = Split-Path -Parent $TargetPath
    $temporary = Join-Path $directory (
        ".claude-easy-recovery-" + [Guid]::NewGuid().ToString("N") + ".tmp"
    )
    $stream = $null
    $handle = $null
    $completedBytes = $null
    $completedIdentity = $null
    $failure = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::CreatePrivateFile($temporary)
        $stream = New-Object System.IO.FileStream(
            $handle,
            [System.IO.FileAccess]::ReadWrite
        )
        $handle = $null
        if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint(
                $stream.SafeFileHandle
            ) -or
            [ClaudeEasy.VerifiedDeleteNative]::GetLinkCount(
                $stream.SafeFileHandle
            ) -ne 1) {
            throw "中断事务恢复临时文件不能是链接：$temporary"
        }
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.SetLength($Bytes.Length)
        $stream.Flush($true)
        $completedBytes = Get-StreamBytes $stream
        $completedIdentity = [ClaudeEasy.VerifiedDeleteNative]::GetIdentity(
            $stream.SafeFileHandle
        )
        if ((Get-BytesSha256 $completedBytes) -ne (Get-BytesSha256 $Bytes)) {
            throw "中断事务恢复临时文件内容不正确：$temporary"
        }
    } catch {
        $failure = $_
        if ($null -ne $stream) {
            try {
                Set-VerifiedDeleteDisposition $stream $true
            } catch {
                throw "中断事务恢复临时文件写入失败，且清理失败：$($_.Exception.Message)"
            }
        }
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
    }
    if ($null -ne $failure) { throw $failure }
    return [pscustomobject]@{
        Path = $temporary
        Bytes = $completedBytes
        Identity = $completedIdentity
    }
}

function Remove-InterruptedRecoveryTemporaryFile([object]$Temporary) {
    if ($null -eq $Temporary -or
        [string]::IsNullOrWhiteSpace([string]$Temporary.Path)) {
        return
    }
    $snapshot = Get-OptionalFileSnapshot (
        [string]$Temporary.Path
    ) "中断事务恢复临时文件"
    if (-not $snapshot.Exists) { return }
    if ((Get-BytesSha256 $snapshot.Bytes) -ne
        (Get-BytesSha256 ([byte[]]$Temporary.Bytes))) {
        throw "中断事务恢复临时文件在清理前发生变化：$($Temporary.Path)"
    }
    $directoryHandles = @(
        Open-VerifiedDirectoryChain (Split-Path -Parent ([string]$Temporary.Path))
    )
    $handle = $null
    $stream = $null
    try {
        $handle = [ClaudeEasy.VerifiedDeleteNative]::Open(
            [string]$Temporary.Path,
            $false,
            $false
        )
        $stream = New-Object System.IO.FileStream($handle, [System.IO.FileAccess]::Read)
        $handle = $null
        if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint(
                $stream.SafeFileHandle
            ) -or
            [ClaudeEasy.VerifiedDeleteNative]::GetLinkCount(
                $stream.SafeFileHandle
            ) -ne 1 -or
            [ClaudeEasy.VerifiedDeleteNative]::GetIdentity(
                $stream.SafeFileHandle
            ) -cne $snapshot.Identity -or
            (Get-BytesSha256 (Get-StreamBytes $stream)) -ne
                (Get-BytesSha256 ([byte[]]$Temporary.Bytes))) {
            throw "中断事务恢复临时文件在清理前再次发生变化：$($Temporary.Path)"
        }
        Set-VerifiedDeleteDisposition $stream $true
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        } elseif ($null -ne $handle) {
            $handle.Dispose()
        }
        for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
            $directoryHandles[$index].Dispose()
        }
    }
}

function Undo-InterruptedTransactionRecovery([object[]]$Opened) {
    foreach ($entry in @($Opened | Where-Object {
        $_.Item.Operation -eq "delete"
    })) {
        Set-VerifiedDeleteDisposition $entry.Stream $false
    }
    foreach ($entry in @($Opened | Where-Object {
        $_.Item.Operation -eq "write"
    })) {
        Write-LockedStreamBytes `
            $entry.Stream `
            $entry.Current `
            $entry.Item.Action.Original
    }
    foreach ($entry in @($Opened | Where-Object {
        $_.Item.Operation -eq "create" -and $_.Published
    })) {
        if ($null -ne $entry.Stream) {
            Set-VerifiedDeleteDisposition $entry.Stream $true
        } else {
            Remove-InterruptedRecoveryTemporaryFile ([pscustomobject]@{
                Path = $entry.Item.Action.Path
                Bytes = $entry.Item.Action.Original
            })
        }
    }
    foreach ($entry in @($Opened | Where-Object {
        $_.Item.Operation -eq "write"
    })) {
        if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne
            (Get-BytesSha256 $entry.Current)) {
            throw "中断事务末检拒绝后的回退失败：$($entry.Item.Action.Path)"
        }
    }
}

function Invoke-InterruptedTransactionRecovery(
    [object[]]$Plan,
    [scriptblock]$PreCommitCondition = $null,
    [scriptblock]$FinalizeCondition = $null
) {
    Initialize-VerifiedFileNative
    $opened = @()
    $directoryHandles = @()
    $operationFailure = $null
    $preCommitRejected = $false
    $finalizeRejected = $false
    $mutationsApplied = $false
    $rollbackCompleted = $false
    $cleanupFailures = @()
    foreach ($item in @($Plan | Sort-Object { $_.Action.Path })) {
        $handle = $null
        $stream = $null
        $create = $item.Operation -eq "create"
        $verifyAbsent = $item.Operation -eq "verify_absent"
        try {
            $directoryHandles += @(
                Open-VerifiedDirectoryChain (Split-Path -Parent $item.Action.Path)
            )
            if (($create -or $verifyAbsent) -and (Test-Path -LiteralPath $item.Action.Path)) {
                throw "中断事务待重建目标在恢复前出现：$($item.Action.Path)"
            }
            if ($create -or $verifyAbsent) {
                $opened += [pscustomobject]@{
                    Item = $item
                    Stream = $null
                    Current = $null
                    Temporary = $null
                    Published = $false
                }
                continue
            }
            $writable = $item.Operation -eq "write"
            $handle = [ClaudeEasy.VerifiedDeleteNative]::Open(
                $item.Action.Path,
                $writable,
                $false
            )
            $access = if ($writable) {
                [System.IO.FileAccess]::ReadWrite
            } else {
                [System.IO.FileAccess]::Read
            }
            $stream = New-Object System.IO.FileStream($handle, $access)
            if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle) -or
                [ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
                throw "中断事务目标不能是链接：$($item.Action.Path)"
            }
            $current = Get-StreamBytes $stream
            if ([ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle) -cne
                $item.Snapshot.Identity -or
                (Get-BytesSha256 $current) -ne
                    (Get-BytesSha256 $item.Snapshot.Bytes)
            ) {
                throw "中断事务目标在恢复前再次发生变化：$($item.Action.Path)"
            }
            $opened += [pscustomobject]@{
                Item = $item
                Stream = $stream
                Current = $current
                Temporary = $null
                Published = $false
            }
        } catch {
            $caughtFailure = $_
            if ($null -ne $stream) { $stream.Dispose() } elseif ($null -ne $handle) { $handle.Dispose() }
            $operationFailure = $caughtFailure
            break
        }
    }
    if ($null -eq $operationFailure) {
        try {
            $preCommitRejected = -not (
                Test-InterruptedRecoveryCommitCondition $PreCommitCondition
            )
            if (-not $preCommitRejected) {
                $mutationsApplied = $true
                foreach ($entry in @($opened | Where-Object {
                    $_.Item.Operation -eq "create"
                })) {
                    $entry.Temporary = New-InterruptedRecoveryTemporaryFile `
                        $entry.Item.Action.Path `
                        $entry.Item.Action.Original
                }
                foreach ($entry in @($opened | Where-Object {
                    $_.Item.Operation -eq "write"
                })) {
                    Write-LockedStreamBytes `
                        $entry.Stream `
                        $entry.Item.Action.Original `
                        $entry.Current
                }
                foreach ($entry in @($opened | Where-Object {
                    $_.Item.Operation -eq "write"
                })) {
                    if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne
                        (Get-BytesSha256 $entry.Item.Action.Original)) {
                        throw "中断事务写入后的内容不正确：$($entry.Item.Action.Path)"
                    }
                }
                foreach ($entry in @($opened | Where-Object {
                    $_.Item.Operation -eq "create"
                })) {
                    if (Test-Path -LiteralPath $entry.Item.Action.Path) {
                        throw "中断事务待重建目标在发布前出现：$($entry.Item.Action.Path)"
                    }
                    [System.IO.File]::Move(
                        $entry.Temporary.Path,
                        $entry.Item.Action.Path
                    )
                    $entry.Published = $true
                    $publishedHandle = [ClaudeEasy.VerifiedDeleteNative]::Open(
                        $entry.Item.Action.Path,
                        $false,
                        $false
                    )
                    $entry.Stream = New-Object System.IO.FileStream(
                        $publishedHandle,
                        [System.IO.FileAccess]::Read
                    )
                    $entry.Current = Get-StreamBytes $entry.Stream
                    if ([ClaudeEasy.VerifiedDeleteNative]::GetIdentity(
                            $entry.Stream.SafeFileHandle
                        ) -cne $entry.Temporary.Identity -or
                        (Get-BytesSha256 $entry.Current) -ne
                            (Get-BytesSha256 $entry.Item.Action.Original)) {
                        throw "中断事务重建目标发布后的内容不正确：$($entry.Item.Action.Path)"
                    }
                }
                foreach ($entry in @($opened | Where-Object {
                    $_.Item.Operation -eq "delete"
                })) {
                    Set-VerifiedDeleteDisposition $entry.Stream $true
                }
                foreach ($entry in $opened) {
                    if ($entry.Item.Operation -eq "verify_absent") {
                        if (Test-Path -LiteralPath $entry.Item.Action.Path) {
                            throw "中断事务缺失目标在最终核对前出现：$($entry.Item.Action.Path)"
                        }
                    } elseif ($entry.Item.Operation -ne "delete" -and
                        (Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne
                            (Get-BytesSha256 $entry.Item.Action.Original)) {
                        throw "中断事务最终核对失败：$($entry.Item.Action.Path)"
                    }
                }
                if ($null -ne $FinalizeCondition) {
                    $finalizeResults = @(& $FinalizeCondition)
                    if ($finalizeResults.Count -ne 1 -or
                        -not ($finalizeResults[0] -is [bool])) {
                        throw "中断事务最终条件必须只返回一个布尔值。"
                    }
                    $finalizeRejected = -not [bool]$finalizeResults[0]
                }
                if ($finalizeRejected) {
                    Undo-InterruptedTransactionRecovery $opened
                    $rollbackCompleted = $true
                }
            }
        } catch {
            $operationFailure = $_
            if ($mutationsApplied -and -not $rollbackCompleted) {
                try {
                    Undo-InterruptedTransactionRecovery $opened
                    $rollbackCompleted = $true
                } catch {
                    $operationFailure = $_
                }
            }
        }
    }
    foreach ($entry in @($opened | Where-Object {
        $null -ne $_.Temporary -and -not $_.Published
    })) {
        try {
            Remove-InterruptedRecoveryTemporaryFile $entry.Temporary
        } catch {
            $cleanupFailures += "$($entry.Item.Action.Path)：删除恢复临时文件失败。"
        }
    }
    for ($index = $opened.Count - 1; $index -ge 0; $index--) {
        if ($null -eq $opened[$index].Stream) { continue }
        try {
            $opened[$index].Stream.Dispose()
        } catch {
            $cleanupFailures += "$($opened[$index].Item.Action.Path)：关闭恢复文件失败。"
        }
    }
    for ($index = $directoryHandles.Count - 1; $index -ge 0; $index--) {
        try {
            $directoryHandles[$index].Dispose()
        } catch {
            $cleanupFailures += "关闭恢复目标目录失败。"
        }
    }
    if ($cleanupFailures.Count -gt 0) {
        throw ("中断事务恢复清理失败：" + ($cleanupFailures -join "；"))
    }
    if ($null -ne $operationFailure) { throw $operationFailure }
    return (-not $preCommitRejected -and -not $finalizeRejected)
}

function Assert-InterruptedTransactionRecovered([object[]]$Actions) {
    foreach ($action in $Actions) {
        $snapshot = Get-OptionalFileSnapshot $action.Path "中断事务恢复结果"
        if ($action.Action -eq "write" -and -not $action.Existed) {
            if ($snapshot.Exists) { throw "中断事务新建文件未删除：$($action.Path)" }
        } elseif (-not $snapshot.Exists -or
            (Get-BytesSha256 $snapshot.Bytes) -ne (Get-BytesSha256 $action.Original)) {
            throw "中断事务未恢复原文件：$($action.Path)"
        }
    }
}

function Repair-InterruptedFileTransaction {
    $path = [string]$script:ClaudeEasyTransactionJournalPath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    $snapshot = Get-OptionalFileSnapshot $path "文件事务记录"
    if (-not $snapshot.Exists) { return }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($snapshot.Bytes)
        if ([regex]::Matches($text, '(?i)"Version"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"Actions"\s*:').Count -ne 1 -or
            [regex]::Matches($text, '(?i)"RecoveryPolicy"\s*:').Count -gt 1) {
            throw "字段重复或缺失。"
        }
        $journal = $text | ConvertFrom-Json
        $actions = @(Get-ValidatedFileTransactionJournal $journal)
        $recoveryPolicy = Get-InterruptedRecoveryPolicy $journal
    } catch {
        throw "文件事务记录损坏，无法安全恢复。"
    }
    $plan = @(Get-InterruptedTransactionRecoveryPlan $actions)
    $actionPaths = @()
    foreach ($action in $actions) { $actionPaths += [string]$action.Path }
    $preCommitCondition = $null
    if (Test-InterruptedRecoveryRequiresStoppedClient `
        $recoveryPolicy $actionPaths) {
        if (Test-ClashVergeRunning) {
            throw "客户端保持运行；中断的客户端敏感事务等待恢复。"
        }
        $preCommitCondition = { -not (Test-ClashVergeRunning) }
    }
    $finalizeCondition = {
        if (-not (Test-InterruptedRecoveryCommitCondition $preCommitCondition)) {
            return $false
        }
        Remove-FileTransactionJournal $snapshot.Bytes
        return $true
    }
    $recovered = Invoke-InterruptedTransactionRecovery `
        $plan `
        $preCommitCondition `
        $finalizeCondition
    if (-not $recovered) {
        throw "客户端保持运行；中断的客户端敏感事务等待恢复。"
    }
}

function Invoke-VerifiedPathTransaction(
    [object[]]$WriteTargets,
    [object[]]$DeleteTargets,
    [scriptblock]$PreCommitCondition = $null,
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    $writePathKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $actions = @()
    foreach ($writeTarget in @($WriteTargets)) {
        if ([string]::IsNullOrWhiteSpace([string]$writeTarget.Path)) { throw "事务写入目标路径无效。" }
        $pathKey = [System.IO.Path]::GetFullPath([string]$writeTarget.Path)
        if (-not $writePathKeys.Add($pathKey)) { throw "事务包含重复写入目标：$($writeTarget.Path)" }
        $actions += [pscustomobject]@{
            Action = "write"
            Path = [string]$writeTarget.Path
            Target = $writeTarget
            Writable = $true
            CreateNew = (-not [bool]$writeTarget.Existed)
        }
    }
    $deletePathKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($deleteTarget in @($DeleteTargets)) {
        if ([string]::IsNullOrWhiteSpace([string]$deleteTarget.Path)) { throw "事务删除目标路径无效。" }
        $pathKey = [System.IO.Path]::GetFullPath([string]$deleteTarget.Path)
        if (-not $deletePathKeys.Add($pathKey)) { throw "事务包含重复删除目标：$($deleteTarget.Path)" }
        if ($writePathKeys.Contains($pathKey)) { throw "事务不能同时写入并删除同一路径：$($deleteTarget.Path)" }
        if (-not [bool]$deleteTarget.Existed) { throw "事务删除目标必须是已经存在的文件：$($deleteTarget.Path)" }
        $actions += [pscustomobject]@{
            Action = "delete"
            Path = [string]$deleteTarget.Path
            Target = $deleteTarget
            Writable = $false
            CreateNew = $false
        }
    }

    foreach ($action in $actions) {
        Assert-NoReparsePointPath $action.Path "事务目标"
    }
    $actionPaths = @()
    foreach ($action in $actions) { $actionPaths += [string]$action.Path }
    Test-InterruptedRecoveryRequiresStoppedClient `
        $InterruptedRecoveryPolicy $actionPaths | Out-Null
    Initialize-VerifiedFileNative
    $opened = @()
    $directoryHandles = @()
    $markedDeletes = @()
    $journalBytes = $null
    $preparationBytes = $null
    $operationFailure = $null
    $preCommitRejected = $false
    $mutationStarted = $false
    $recoveryFailures = @()
    try {
        foreach ($action in @($actions | Sort-Object Path)) {
            if ($action.CreateNew) {
                if (Test-Path -LiteralPath $action.Path) {
                    throw "目标路径在候选生成后出现，拒绝覆盖：$($action.Path)"
                }
            } elseif (-not (Test-Path -LiteralPath $action.Path -PathType Leaf)) {
                throw "事务目标在候选生成后消失或不再是文件：$($action.Path)"
            }
        }
        $preparationBytes = Write-FileTransactionPreparation $actions $InterruptedRecoveryPolicy
        foreach ($action in @($actions | Sort-Object Path)) {
            $directory = Split-Path -Parent $action.Path
            $directoryHandles += @(Open-VerifiedDirectoryChain $directory)
            if ($action.CreateNew) {
                if (Test-Path -LiteralPath $action.Path) {
                    throw "目标路径在候选生成后出现，拒绝覆盖：$($action.Path)"
                }
            } elseif (-not (Test-Path -LiteralPath $action.Path -PathType Leaf)) {
                throw "事务目标在候选生成后消失或不再是文件：$($action.Path)"
            }

            $handle = [ClaudeEasy.VerifiedDeleteNative]::Open(
                $action.Path,
                [bool]$action.Writable,
                [bool]$action.CreateNew
            )
            $stream = $null
            try {
                if ([ClaudeEasy.VerifiedDeleteNative]::IsReparsePoint($handle)) {
                    throw "事务目标不能是符号链接或其他重解析点：$($action.Path)"
                }
                if ([ClaudeEasy.VerifiedDeleteNative]::GetLinkCount($handle) -ne 1) {
                    throw "事务目标不能有硬链接别名：$($action.Path)"
                }
                $access = if ($action.Writable) { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
                $stream = New-Object System.IO.FileStream($handle, $access)
            } catch {
                if ($null -ne $stream) { $stream.Dispose() } else { $handle.Dispose() }
                throw
            }
            $entry = [pscustomobject]@{
                Action = $action.Action
                Target = $action.Target
                Stream = $stream
                Original = [byte[]]@()
                Created = [bool]$action.CreateNew
            }
            $opened += $entry
            $current = Get-StreamBytes $stream
            $entry.Original = $current
            if ($action.CreateNew) {
                if ($current.Length -ne 0) { throw "新建事务目标不是空文件：$($action.Path)" }
            } else {
                $identityProperty = $action.Target.PSObject.Properties["OriginalIdentity"]
                if ($null -eq $identityProperty -or [string]::IsNullOrWhiteSpace([string]$identityProperty.Value)) {
                    throw "事务目标缺少候选生成时的文件身份：$($action.Path)"
                }
                if ([ClaudeEasy.VerifiedDeleteNative]::GetIdentity($handle) -cne [string]$identityProperty.Value -or
                    (Get-BytesSha256 $current) -ne (Get-BytesSha256 $action.Target.OriginalBytes)) {
                    throw "事务目标在候选生成后发生变化，拒绝继续：$($action.Path)"
                }
            }
        }

        if ($null -ne $PreCommitCondition) {
            $preCommitResults = @(& $PreCommitCondition)
            if ($preCommitResults.Count -ne 1 -or -not ($preCommitResults[0] -is [bool])) {
                throw "事务提交条件必须只返回一个布尔值。"
            }
            $preCommitRejected = -not [bool]$preCommitResults[0]
        }
        if (-not $preCommitRejected) {
            $journalBytes = Write-FileTransactionJournal $opened $InterruptedRecoveryPolicy
            if ($null -ne $preparationBytes) {
                Remove-FileTransactionPreparation $preparationBytes
            }
            foreach ($entry in @($opened | Where-Object { $_.Action -eq "write" })) {
                $mutationStarted = $true
                Write-LockedStreamBytes $entry.Stream $entry.Target.Bytes $entry.Original
            }
            foreach ($entry in @($opened | Where-Object { $_.Action -eq "write" })) {
                if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne (Get-BytesSha256 $entry.Target.Bytes)) {
                    throw "写入后的文件与已验证候选不一致：$($entry.Target.Path)"
                }
            }
            foreach ($entry in @($opened | Where-Object { $_.Action -eq "delete" })) {
                $mutationStarted = $true
                Set-VerifiedDeleteDisposition $entry.Stream $true
                $markedDeletes += $entry
            }
        }
    } catch {
        $operationFailure = $_
    }

    if ($null -ne $operationFailure -or $preCommitRejected) {
        for ($i = $markedDeletes.Count - 1; $i -ge 0; $i--) {
            try {
                Set-VerifiedDeleteDisposition $markedDeletes[$i].Stream $false
            } catch {
                $recoveryFailures += "$($markedDeletes[$i].Target.Path)：取消删除失败：$($_.Exception.Message)"
            }
        }
        for ($i = $opened.Count - 1; $i -ge 0; $i--) {
            $entry = $opened[$i]
            if ($entry.Action -ne "write") { continue }
            if ($entry.Created) {
                try {
                    Set-VerifiedDeleteDisposition $entry.Stream $true
                } catch {
                    $recoveryFailures += "$($entry.Target.Path)：删除事务新建文件失败：$($_.Exception.Message)"
                }
            } elseif ($mutationStarted) {
                try {
                    Write-LockedStreamBytes $entry.Stream $entry.Original (Get-StreamBytes $entry.Stream)
                    if ((Get-BytesSha256 (Get-StreamBytes $entry.Stream)) -ne (Get-BytesSha256 $entry.Original)) {
                        throw "恢复后的内容与原文件不一致。"
                    }
                } catch {
                    $recoveryFailures += "$($entry.Target.Path)：恢复原文件失败：$($_.Exception.Message)"
                }
            }
        }
    }

    for ($i = $opened.Count - 1; $i -ge 0; $i--) {
        try {
            $opened[$i].Stream.Dispose()
        } catch {
            $recoveryFailures += "$($opened[$i].Target.Path)：关闭事务文件失败：$($_.Exception.Message)"
        }
    }
    for ($i = $directoryHandles.Count - 1; $i -ge 0; $i--) {
        try {
            $directoryHandles[$i].Dispose()
        } catch {
            $recoveryFailures += "关闭事务目标目录失败：$($_.Exception.Message)"
        }
    }
    if ($null -ne $preparationBytes -and $recoveryFailures.Count -eq 0) {
        try {
            Remove-FileTransactionPreparation $preparationBytes
        } catch {
            $recoveryFailures += "清理新建文件准备记录失败：$($_.Exception.Message)"
        }
    }
    if ($null -ne $journalBytes -and $recoveryFailures.Count -eq 0) {
        try {
            Remove-FileTransactionJournal $journalBytes
        } catch {
            $journalFailure = $_
            try {
                Repair-InterruptedFileTransaction
            } catch {
                $recoveryFailures += "清理事务记录失败：$($journalFailure.Exception.Message)；自动恢复失败：$($_.Exception.Message)"
            }
            if ($null -eq $operationFailure) { $operationFailure = $journalFailure }
        }
    }
    if ($recoveryFailures.Count -gt 0) {
        $operationMessage = if ($null -eq $operationFailure) {
            "提交条件拒绝后的文件清理失败"
        } else {
            $operationFailure.Exception.Message
        }
        throw ("事务失败：$operationMessage；回滚未能恢复所有文件：" + ($recoveryFailures -join "；"))
    }
    if ($null -ne $operationFailure) { throw $operationFailure }
    return (-not $preCommitRejected)
}

function Invoke-VerifiedFileTransaction(
    [object[]]$Targets,
    [scriptblock]$PreCommitCondition = $null,
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    $committed = Invoke-VerifiedPathTransaction $Targets @() $PreCommitCondition $InterruptedRecoveryPolicy
    if ($null -ne $PreCommitCondition) {
        return [bool]$committed
    }
}

function Invoke-VerifiedWriteDeleteTransaction(
    [object[]]$WriteTargets,
    [object[]]$DeleteTargets,
    [scriptblock]$PreCommitCondition = $null,
    [string]$InterruptedRecoveryPolicy = "client_stopped"
) {
    $committed = Invoke-VerifiedPathTransaction $WriteTargets $DeleteTargets $PreCommitCondition $InterruptedRecoveryPolicy
    if ($null -ne $PreCommitCondition) {
        return [bool]$committed
    }
}


function Get-InstallStateEntry([object]$State, [string]$Name) {
    if ($null -eq $State) { return $null }
    $property = $State.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Assert-InstallStateEntry([object]$Entry, [string]$Label) {
    if ($null -eq $Entry) { throw "安装状态文件无效：缺少 $Label。" }
    $propertyNames = @($Entry.PSObject.Properties.Name | Sort-Object)
    if (($propertyNames -join ",") -cne "Existed,InstalledSha256,OriginalBase64") {
        throw "安装状态文件无效：$Label 字段无效。"
    }
    if (-not ($Entry.Existed -is [bool])) { throw "安装状态文件无效：$Label.Existed 不是布尔值。" }
    if (-not ($Entry.OriginalBase64 -is [string])) { throw "安装状态文件无效：$Label.OriginalBase64 不是字符串。" }
    if (-not ($Entry.InstalledSha256 -is [string]) -or [string]$Entry.InstalledSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "安装状态文件无效：$Label.InstalledSha256 不是 SHA-256。"
    }
    $encoded = [string]$Entry.OriginalBase64
    try {
        $decoded = [Convert]::FromBase64String($encoded)
    } catch {
        throw "安装状态文件无效：$Label.OriginalBase64 不是 Base64。"
    }
    if ([Convert]::ToBase64String($decoded) -cne $encoded) {
        throw "安装状态文件无效：$Label.OriginalBase64 不是规范 Base64。"
    }
    if (-not [bool]$Entry.Existed -and $encoded.Length -ne 0) {
        throw "安装状态文件无效：$Label 不存在却保存了原始内容。"
    }
}

function Assert-InstallState([object]$State) {
    if ($null -eq $State) { throw "安装状态文件无效。" }
    $propertyNames = @($State.PSObject.Properties.Name | Sort-Object)
    if (($propertyNames -join ",") -cne "ConfigYaml,VergeYaml,Version") {
        throw "安装状态文件无效：字段无效。"
    }
    $version = $State.Version
    $numericVersion = $version -is [int] -or $version -is [long]
    if (-not $numericVersion -or [long]$version -ne 1) { throw "安装状态文件无效：版本不受支持。" }
    Assert-InstallStateEntry (Get-InstallStateEntry $State "VergeYaml") "VergeYaml"
    Assert-InstallStateEntry (Get-InstallStateEntry $State "ConfigYaml") "ConfigYaml"
}

function Assert-StateSnapshotUnchanged([object]$Entry, [object]$Snapshot, [string]$Label) {
    if ($null -eq $Entry) { return }
    $expected = [string]$Entry.InstalledSha256
    $actual = if ([bool]$Snapshot.Exists) { Get-BytesSha256 $Snapshot.Bytes } else { "" }
    if ($actual -ne $expected) {
        throw "$Label 在上次安装后被其他程序修改。为避免覆盖这些改动，请先卸载补丁或备份并手动处理该文件。"
    }
}

function New-InstallStateEntry([object]$Previous, [string]$Path, [byte[]]$InstalledBytes) {
    if ($null -ne $Previous) {
        $existed = [bool]$Previous.Existed
        $originalBase64 = [string]$Previous.OriginalBase64
    } else {
        $existed = Test-Path -LiteralPath $Path -PathType Leaf
        $originalBase64 = if ($existed) { [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($Path)) } else { "" }
    }
    return [ordered]@{
        Existed = $existed
        OriginalBase64 = $originalBase64
        InstalledSha256 = (Get-BytesSha256 $InstalledBytes)
    }
}
