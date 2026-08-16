#Requires -Version 5.1

<#
.SYNOPSIS
Installs InvenTree and its USD/IRT and stock XLSX plugins with Docker Desktop.

.DESCRIPTION
Online mode downloads pinned application inputs, builds the plugin image, and
exports a reusable Windows offline application bundle by default. The bundle
retains the pinned official training dataset, WSL installer, and Docker Desktop
installer for a first-time install without network access. Docker Desktop
license acceptance is still required on the target machine.

.PARAMETER TrainingData
Populates a new empty installation with the comprehensive official InvenTree
demo dataset and a sample offline USD/IRT rate. Refuses existing installations.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$InstallDirectory = (Join-Path $HOME 'InvenTree'),

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$HttpPort = 8000,

    [Parameter()]
    [string]$OfflineBundle,

    [Parameter()]
    [string]$BundleDirectory,

    [Parameter()]
    [switch]$SkipDockerInstall,

    [Parameter()]
    [switch]$SkipAdmin,

    [Parameter()]
    [switch]$TrainingData,

    [Parameter()]
    [switch]$PrepareOnly,

    [Parameter()]
    [switch]$NoOfflineCache,

    [Parameter()]
    [switch]$AcceptDockerLicense
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:AssetRoot = $script:ScriptDirectory
$script:Versions = @{}
$script:Bundle = @{}
$script:DockerCommand = $null
$script:EffectiveHttpPort = $HttpPort
$script:WslInstallerPath = $null
$script:InventreeDeployImage = $null
$script:PostgresDeployImage = $null
$script:RedisDeployImage = $null
$script:CaddyDeployImage = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host ''
    Write-Host "==> $Message"
}

function Throw-InstallerError {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw "Installer error: $Message"
}

function Resolve-AbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ($expanded -eq '~') {
        $expanded = $HOME
    }
    elseif ($expanded.StartsWith('~\') -or $expanded.StartsWith('~/')) {
        $expanded = Join-Path $HOME $expanded.Substring(2)
    }

    if (-not [IO.Path]::IsPathRooted($expanded)) {
        $expanded = Join-Path (Get-Location).Path $expanded
    }

    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath -ne $root) {
        $fullPath = $fullPath.TrimEnd('\', '/')
    }
    return $fullPath
}

function Assert-NoReparsePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $current = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-InstallerError "$Label path contains a reparse point: $current"
            }
        }

        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )

    [IO.File]::WriteAllText($Path, $Content, $script:Utf8NoBom)
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-RegularFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Throw-InstallerError "Missing file: $Path"
    }

    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-InstallerError "Refusing reparse-point file: $Path"
    }
}

function Assert-RealDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter()][switch]$Create
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $Create) {
            Throw-InstallerError "Missing directory: $Path"
        }
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        Throw-InstallerError "$Label is not a directory: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-InstallerError "$Label cannot be a reparse point: $Path"
    }
}

function Assert-NoReparseTree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Assert-RealDirectory -Path $Root -Label $Label
    $pending = New-Object 'Collections.Generic.Stack[string]'
    $pending.Push([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $current = $pending.Pop()
        foreach ($item in Get-ChildItem -LiteralPath $current -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-InstallerError "$Label contains a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push($item.FullName)
            }
        }
    }
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Candidate,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $candidateFull = (Resolve-AbsolutePath -Path $Candidate).TrimEnd('\', '/')
    $parentFull = (Resolve-AbsolutePath -Path $Parent).TrimEnd('\', '/')
    if ($candidateFull.Equals($parentFull, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    return $candidateFull.StartsWith(
        $parentFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
}

function Read-StrictKeyValueFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-RegularFile -Path $Path
    $values = @{}
    $lineNumber = 0

    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $lineNumber++
        if ($line.Length -eq 0 -or $line.StartsWith('#')) {
            continue
        }

        if ($line -notmatch '^([A-Z][A-Z0-9_]*)=(.*)$') {
            Throw-InstallerError "Invalid KEY=VALUE line in $Path at line ${lineNumber}"
        }

        $key = $Matches[1]
        if ($values.ContainsKey($key)) {
            Throw-InstallerError "Duplicate key '$key' in $Path"
        }

        $values[$key] = $Matches[2]
    }

    return $values
}

function Assert-RequiredKeys {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    foreach ($key in $Keys) {
        if (-not $Values.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($Values[$key])) {
            Throw-InstallerError "Missing required key '$key' in $SourceName"
        }
    }
}

function Assert-OnlyKeys {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string[]]$Keys,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    $allowed = @{}
    foreach ($key in $Keys) {
        $allowed[$key] = $true
    }
    foreach ($key in $Values.Keys) {
        if (-not $allowed.ContainsKey($key)) {
            Throw-InstallerError "Unknown key '$key' in $SourceName"
        }
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][switch]$CaptureOutput
    )

    if ($CaptureOutput) {
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
        $text = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        if ($exitCode -ne 0) {
            Throw-InstallerError "Command failed with exit code ${exitCode}: $FilePath $($ArgumentList -join ' ')`n$text"
        }
        return $text.Trim()
    }

    & $FilePath @ArgumentList
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Throw-InstallerError "Command failed with exit code ${exitCode}: $FilePath $($ArgumentList -join ' ')"
    }
}

function Test-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @()
    )

    try {
        & $FilePath @ArgumentList *> $null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Get-LastOutputLine {
    param([Parameter(Mandatory = $true)][string]$Output)

    $lines = @($Output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        return ''
    }
    return $lines[$lines.Count - 1].Trim()
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter()][switch]$CaptureOutput
    )

    if ([string]::IsNullOrWhiteSpace($script:DockerCommand)) {
        Throw-InstallerError 'Docker command has not been initialized'
    }

    if ($CaptureOutput) {
        return Invoke-NativeCommand -FilePath $script:DockerCommand -ArgumentList $ArgumentList -CaptureOutput
    }
    Invoke-NativeCommand -FilePath $script:DockerCommand -ArgumentList $ArgumentList
}

function Get-DockerExecutable {
    $command = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }
    return $null
}

function Add-DockerToPath {
    $candidateDirectories = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\resources\bin'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin')
    )

    foreach ($directory in $candidateDirectories) {
        if (Test-Path -LiteralPath (Join-Path $directory 'docker.exe') -PathType Leaf) {
            $pathEntries = @($env:PATH -split ';')
            if ($pathEntries -notcontains $directory) {
                $env:PATH = "$directory;$env:PATH"
            }
        }
    }

    $script:DockerCommand = Get-DockerExecutable
}

function Test-DockerUsable {
    Add-DockerToPath
    if ([string]::IsNullOrWhiteSpace($script:DockerCommand)) {
        return $false
    }

    if (-not (Test-NativeCommand -FilePath $script:DockerCommand -ArgumentList @('info'))) {
        return $false
    }
    return Test-NativeCommand -FilePath $script:DockerCommand -ArgumentList @('compose', 'version')
}

function Get-DockerDesktopExecutable {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\Docker Desktop.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Docker\Docker\Docker Desktop.exe'),
        (Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe')
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    return $null
}

function Wait-ForDocker {
    param([ValidateRange(30, 600)][int]$TimeoutSeconds = 180)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-DockerUsable) {
            return $true
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Start-DockerDesktop {
    Add-DockerToPath
    if (-not [string]::IsNullOrWhiteSpace($script:DockerCommand)) {
        if (Test-NativeCommand -FilePath $script:DockerCommand -ArgumentList @('desktop', 'start', '--timeout', '180')) {
            if (Wait-ForDocker -TimeoutSeconds 30) {
                return
            }
        }
    }

    $desktop = Get-DockerDesktopExecutable
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        return
    }

    Write-Step 'Starting Docker Desktop'
    Start-Process -FilePath $desktop | Out-Null
    if (-not (Wait-ForDocker -TimeoutSeconds 180)) {
        Throw-InstallerError 'Docker Desktop did not become ready within three minutes'
    }
}

function Assert-WindowsHost {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        Throw-InstallerError 'This script supports Windows only'
    }
    if ($PSVersionTable.PSVersion -lt [Version]'5.1') {
        Throw-InstallerError 'PowerShell 5.1 or newer is required'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        Throw-InstallerError 'A 64-bit Windows installation is required'
    }

    $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
    if ([string]::IsNullOrWhiteSpace($nativeArchitecture)) {
        $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE
    }
    if ($nativeArchitecture -ne 'AMD64') {
        Throw-InstallerError 'This installer supports x86-64 Windows only; Windows ARM64 is not supported'
    }

    try {
        $operatingSystem = Get-CimInstance Win32_OperatingSystem
        $caption = [string]$operatingSystem.Caption
        $build = [int]$operatingSystem.BuildNumber
        if ($caption -match 'Server') {
            Throw-InstallerError 'Docker Desktop does not support Windows Server'
        }
        if ($caption -match 'Windows 10' -and $build -lt 19045) {
            Throw-InstallerError 'Docker Desktop requires Windows 10 22H2 build 19045 or newer'
        }
        if ($caption -match 'Windows 11' -and $build -lt 22631) {
            Throw-InstallerError 'Docker Desktop requires Windows 11 23H2 build 22631 or newer'
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith('Installer error:')) {
            throw
        }
        Write-Warning "Could not confirm the Windows release: $($_.Exception.Message)"
    }
}

function Assert-DockerHostPrerequisites {
    try {
        $computer = Get-CimInstance Win32_ComputerSystem
        if ([uint64]$computer.TotalPhysicalMemory -lt [uint64]8589934592) {
            Throw-InstallerError 'Docker Desktop requires at least 8 GB of RAM'
        }

        $processor = Get-CimInstance Win32_Processor | Select-Object -First 1
        if ($null -ne $processor.SecondLevelAddressTranslationExtensions -and
            -not [bool]$processor.SecondLevelAddressTranslationExtensions) {
            Throw-InstallerError 'The CPU or firmware does not report SLAT support'
        }
        if ($null -ne $processor.VirtualizationFirmwareEnabled -and
            -not [bool]$processor.VirtualizationFirmwareEnabled) {
            Throw-InstallerError 'Hardware virtualization is disabled in BIOS/UEFI'
        }
    }
    catch {
        if ($_.Exception.Message.StartsWith('Installer error:')) {
            throw
        }
        Write-Warning "Could not confirm every Docker hardware prerequisite: $($_.Exception.Message)"
    }
}

function Assert-AuthenticodePublisher {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$PublisherPattern
    )

    Assert-RegularFile -Path $Path
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        Throw-InstallerError "Authenticode signature is not valid for $Path (status: $($signature.Status))"
    }
    if ($null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch $PublisherPattern) {
        Throw-InstallerError "Unexpected Authenticode publisher for $Path"
    }
}

function Save-OnlineFile {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        Throw-InstallerError "Strict offline mode refused a network download: $Uri"
    }

    $parent = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Destination.$([Guid]::NewGuid().ToString('N')).download"

    try {
        [Net.ServicePointManager]::SecurityProtocol =
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Uri -OutFile $temporary -UseBasicParsing
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-OnlineWslInstaller {
    $fileName = "wsl-$($script:Versions.WSL_VERSION)-x64.msi"
    $destination = Join-Path $script:ScriptDirectory "cache\windows\$fileName"

    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-Sha256 -Path $destination) -ne $script:Versions.WSL_SHA256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $destination -Force
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-Step "Downloading pinned WSL $($script:Versions.WSL_VERSION) installer"
        Save-OnlineFile -Uri $script:Versions.WSL_URL -Destination $destination
    }

    if ((Get-Sha256 -Path $destination) -ne $script:Versions.WSL_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'WSL installer SHA-256 mismatch'
    }
    Assert-AuthenticodePublisher -Path $destination -PublisherPattern 'Microsoft Corporation'
    $script:WslInstallerPath = $destination
    return $destination
}

function Get-OnlineDockerDesktopInstaller {
    $fileName = "DockerDesktop-$($script:Versions.DOCKER_DESKTOP_VERSION)-$($script:Versions.DOCKER_DESKTOP_BUILD)-x64.exe"
    $destination = Join-Path $script:ScriptDirectory "cache\windows\$fileName"

    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-Sha256 -Path $destination) -ne $script:Versions.DOCKER_DESKTOP_SHA256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $destination -Force
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-Step "Downloading pinned Docker Desktop $($script:Versions.DOCKER_DESKTOP_VERSION)"
        Save-OnlineFile -Uri $script:Versions.DOCKER_DESKTOP_URL -Destination $destination
    }
    if ((Get-Sha256 -Path $destination) -ne $script:Versions.DOCKER_DESKTOP_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Docker Desktop installer SHA-256 mismatch'
    }
    Assert-AuthenticodePublisher -Path $destination -PublisherPattern 'Docker Inc'
    return $destination
}

function Resolve-BundlePath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        Throw-InstallerError "Bundle path must be relative: $RelativePath"
    }

    $normalized = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $normalized))
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Throw-InstallerError "Bundle path escapes its root: $RelativePath"
    }
    return $candidate
}

function Verify-BundleChecksums {
    param([Parameter(Mandatory = $true)][string]$Root)

    $checksumFile = Join-Path $Root 'SHA256SUMS'
    Assert-RegularFile -Path $checksumFile
    Write-Step 'Verifying offline bundle checksums'
    $entries = @{}
    $lineNumber = 0

    foreach ($line in [IO.File]::ReadAllLines($checksumFile)) {
        $lineNumber++
        if ($line -notmatch '^([a-fA-F0-9]{64})  \./(.+)$') {
            Throw-InstallerError "Invalid SHA256SUMS line at ${lineNumber}"
        }
        $relative = $Matches[2]
        if ($entries.ContainsKey($relative)) {
            Throw-InstallerError "Duplicate SHA256SUMS path: $relative"
        }
        $path = Resolve-BundlePath -Root $Root -RelativePath $relative
        Assert-RegularFile -Path $path
        if ((Get-Sha256 -Path $path) -ne $Matches[1].ToLowerInvariant()) {
            Throw-InstallerError "Offline bundle checksum mismatch: $relative"
        }
        $entries[$relative] = $true
    }

    foreach ($critical in @('versions.env', 'bundle.env', 'compose.yaml', 'Caddyfile', 'env.template', 'Dockerfile', 'install-windows.ps1', 'DOCKER-DESKTOP-LICENSE.txt')) {
        if (-not $entries.ContainsKey($critical)) {
            Throw-InstallerError "SHA256SUMS does not cover required bundle file: $critical"
        }
    }

    return $entries
}

function Assert-BundleFileInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][hashtable]$ChecksumEntries,
        [Parameter(Mandatory = $true)][string[]]$AllowedUnlistedPaths
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $allowedUnlisted = @{}
    foreach ($relative in $AllowedUnlistedPaths) {
        $allowedUnlisted[$relative.Replace('\', '/')] = $true
    }

    Assert-NoReparseTree -Root $rootFull -Label 'Offline bundle'
    foreach ($file in Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-InstallerError "Refusing reparse point in offline bundle: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if ($relative -eq 'SHA256SUMS' -or $ChecksumEntries.ContainsKey($relative) -or
            $allowedUnlisted.ContainsKey($relative)) {
            continue
        }
        Throw-InstallerError "Unexpected file is not covered by the offline bundle manifest: $relative"
    }
}

function Get-OfflineWslInstaller {
    $relative = $script:Bundle.WSL_INSTALLER
    $path = Resolve-BundlePath -Root $OfflineBundle -RelativePath $relative
    Assert-RegularFile -Path $path
    if ((Get-Sha256 -Path $path) -ne $script:Versions.WSL_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Bundled WSL installer SHA-256 mismatch'
    }
    Assert-AuthenticodePublisher -Path $path -PublisherPattern 'Microsoft Corporation'
    $script:WslInstallerPath = $path
    return $path
}

function Invoke-ElevatedProcess {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter()][int[]]$AllowedExitCodes = @(0)
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Verb RunAs -Wait -PassThru
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        Throw-InstallerError "Elevated command failed with exit code $($process.ExitCode): $FilePath"
    }
    return $process.ExitCode
}

function Get-InstalledWslVersion {
    $wsl = Get-Command wsl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $wsl) {
        return $null
    }

    try {
        $output = & $wsl.Source --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        foreach ($line in $output) {
            if ($line.ToString() -match '(\d+\.\d+\.\d+(?:\.\d+)?)') {
                return [Version]$Matches[1]
            }
        }
    }
    catch {
        return $null
    }
    return $null
}

function Install-WslPrerequisites {
    param([Parameter(Mandatory = $true)][string]$InstallerPath)

    Assert-DockerHostPrerequisites
    Write-Step 'Enabling WSL 2 Windows features (administrator approval may be required)'
    $rebootRequired = $false
    foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
        $exitCode = Invoke-ElevatedProcess -FilePath (Join-Path $env:SystemRoot 'System32\dism.exe') `
            -ArgumentList @('/Online', '/Enable-Feature', "/FeatureName:$feature", '/All', '/NoRestart') `
            -AllowedExitCodes @(0, 3010)
        if ($exitCode -eq 3010) {
            $rebootRequired = $true
        }
    }

    $installedVersion = Get-InstalledWslVersion
    $requiredVersion = [Version]$script:Versions.WSL_VERSION
    if ($null -eq $installedVersion -or $installedVersion -lt $requiredVersion) {
        Write-Step "Installing pinned WSL $requiredVersion"
        $exitCode = Invoke-ElevatedProcess -FilePath (Join-Path $env:SystemRoot 'System32\msiexec.exe') `
            -ArgumentList @('/i', ('"{0}"' -f $InstallerPath), '/quiet', '/norestart') `
            -AllowedExitCodes @(0, 3010)
        if ($exitCode -eq 3010) {
            $rebootRequired = $true
        }
    }

    if ($rebootRequired) {
        Throw-InstallerError 'Windows must be restarted to finish enabling WSL 2. This installer never reboots automatically; restart Windows, then rerun the same command.'
    }
}

function Confirm-DockerLicense {
    if ($AcceptDockerLicense) {
        return
    }

    Write-Host ''
    Write-Host 'Docker Desktop requires acceptance of the Docker Subscription Service Agreement:'
    Write-Host 'https://www.docker.com/legal/docker-subscription-service-agreement/'
    try {
        $response = Read-Host 'Type YES to accept the agreement and install Docker Desktop'
    }
    catch {
        Throw-InstallerError 'Docker license acceptance is required. Rerun interactively or pass -AcceptDockerLicense after reviewing the agreement.'
    }
    if ($response -cne 'YES') {
        Throw-InstallerError 'Docker Desktop license was not accepted'
    }
}

function Get-OfflineDockerDesktopInstaller {
    $relative = $script:Bundle.DOCKER_DESKTOP_INSTALLER
    $path = Resolve-BundlePath -Root $OfflineBundle -RelativePath $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Throw-InstallerError "Offline bundle is missing the pinned Docker Desktop installer: $relative"
    }
    if ((Get-Sha256 -Path $path) -ne $script:Versions.DOCKER_DESKTOP_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Separately supplied Docker Desktop installer SHA-256 mismatch'
    }
    Assert-AuthenticodePublisher -Path $path -PublisherPattern 'Docker Inc'
    return $path
}

function Install-DockerDesktop {
    Confirm-DockerLicense
    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        $installer = Get-OfflineDockerDesktopInstaller
    }
    else {
        $installer = Get-OnlineDockerDesktopInstaller
    }

    Write-Step 'Installing Docker Desktop for the current user'
    $process = Start-Process -FilePath $installer -ArgumentList @(
        'install',
        '--user',
        '--backend=wsl-2',
        '--no-windows-containers',
        '--accept-license'
    ) -Wait -PassThru
    if (@(0, 3010) -notcontains $process.ExitCode) {
        Throw-InstallerError "Docker Desktop installer exited with code $($process.ExitCode)"
    }
    if ($process.ExitCode -eq 3010) {
        Throw-InstallerError 'Windows must be restarted to finish Docker Desktop installation. This installer never reboots automatically; restart Windows, then rerun.'
    }
}

function Ensure-Docker {
    if (Test-DockerUsable) {
        Write-Step 'Existing Docker Engine and Compose v2 detected; skipping Docker Desktop installation'
        return
    }

    if ($null -ne (Get-DockerDesktopExecutable)) {
        Start-DockerDesktop
        if (Test-DockerUsable) {
            Write-Step 'Existing Docker Engine and Compose v2 detected; skipping Docker Desktop installation'
            return
        }
    }

    if ($SkipDockerInstall) {
        Throw-InstallerError 'Docker Desktop with Linux containers and Compose v2 is required. Start it and rerun, or omit -SkipDockerInstall.'
    }

    $wslInstaller = $null
    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        $wslInstaller = Get-OfflineWslInstaller
    }
    else {
        $wslInstaller = Get-OnlineWslInstaller
    }
    Install-WslPrerequisites -InstallerPath $wslInstaller
    Install-DockerDesktop
    Add-DockerToPath
    Start-DockerDesktop

    if (-not (Test-DockerUsable)) {
        Throw-InstallerError 'Docker daemon or Compose v2 is not usable after installation'
    }
}

function Assert-DockerPlatform {
    $operatingSystem = (Invoke-Docker -ArgumentList @('info', '--format', '{{.OSType}}') -CaptureOutput).Trim()
    $architecture = (Invoke-Docker -ArgumentList @('info', '--format', '{{.Architecture}}') -CaptureOutput).Trim()
    if ($operatingSystem -ne 'linux') {
        Throw-InstallerError "Docker Desktop must run Linux containers (reported: $operatingSystem)"
    }
    if (@('amd64', 'x86_64') -notcontains $architecture) {
        Throw-InstallerError "Docker Desktop must provide linux/amd64 images (reported: $architecture)"
    }
    Invoke-Docker -ArgumentList @('compose', 'version')
}

function Get-PluginSourceOnline {
    $destination = Join-Path $script:ScriptDirectory 'cache\plugin-source.tar.gz'
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-Sha256 -Path $destination) -ne $script:Versions.PLUGIN_ARCHIVE_SHA256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $destination -Force
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-Step 'Downloading pinned plugin sources'
        Save-OnlineFile -Uri $script:Versions.PLUGIN_ARCHIVE_URL -Destination $destination
    }
    if ((Get-Sha256 -Path $destination) -ne $script:Versions.PLUGIN_ARCHIVE_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Plugin source SHA-256 mismatch'
    }
    return $destination
}

function Get-TrainingDatasetOnline {
    $destination = Join-Path $script:ScriptDirectory 'cache\training-dataset.tar.gz'
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-Sha256 -Path $destination) -ne $script:Versions.TRAINING_DATASET_ARCHIVE_SHA256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $destination -Force
    }
    if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
        Write-Step 'Downloading pinned official training dataset'
        Save-OnlineFile -Uri $script:Versions.TRAINING_DATASET_ARCHIVE_URL -Destination $destination
    }
    if ((Get-Sha256 -Path $destination) -ne $script:Versions.TRAINING_DATASET_ARCHIVE_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Training dataset SHA-256 mismatch'
    }
    return $destination
}

function Get-ImageId {
    param([Parameter(Mandatory = $true)][string]$Reference)

    return (Invoke-Docker -ArgumentList @('image', 'inspect', $Reference, '--format', '{{.Id}}') -CaptureOutput).Trim()
}

function Set-DeploymentImageIds {
    param(
        [Parameter(Mandatory = $true)][string]$InventreeImage,
        [Parameter(Mandatory = $true)][string]$PostgresImage,
        [Parameter(Mandatory = $true)][string]$RedisImage,
        [Parameter(Mandatory = $true)][string]$CaddyImage
    )

    $script:InventreeDeployImage = Get-ImageId -Reference $InventreeImage
    $script:PostgresDeployImage = Get-ImageId -Reference $PostgresImage
    $script:RedisDeployImage = Get-ImageId -Reference $RedisImage
    $script:CaddyDeployImage = Get-ImageId -Reference $CaddyImage
}

function Assert-ImagePlatform {
    param([Parameter(Mandatory = $true)][string]$Reference)

    $platform = (Invoke-Docker -ArgumentList @('image', 'inspect', $Reference, '--format', '{{.Os}}/{{.Architecture}}') -CaptureOutput).Trim()
    if ($platform -ne 'linux/amd64') {
        Throw-InstallerError "Unexpected platform for image ${Reference}: $platform"
    }
}

function Assert-PluginImageVersions {
    param([Parameter(Mandatory = $true)][string]$Reference)

    $output = Invoke-Docker -ArgumentList @(
        'run', '--rm', '--entrypoint', 'python', $Reference, '-c',
        "import importlib.metadata as m; print(m.version('inventree-usd-irt-exchange-rate') + '|' + m.version('inventree-stock-xlsx-adjustment'))"
    ) -CaptureOutput
    $actual = Get-LastOutputLine -Output $output
    $expected = "$($script:Versions.PLUGIN_VERSION)|$($script:Versions.STOCK_PLUGIN_VERSION)"
    if ($actual -ne $expected) {
        Throw-InstallerError "Plugin verification failed: expected $expected, got $actual"
    }
}

function Acquire-ApplicationImages {
    $pluginSource = Get-PluginSourceOnline
    Write-Step 'Pulling pinned InvenTree stack images'
    foreach ($source in @(
        $script:Versions.INVENTREE_BASE_SOURCE,
        $script:Versions.POSTGRES_SOURCE,
        $script:Versions.REDIS_SOURCE,
        $script:Versions.CADDY_SOURCE
    )) {
        Invoke-Docker -ArgumentList @('pull', '--platform', 'linux/amd64', $source)
    }

    Invoke-Docker -ArgumentList @('tag', $script:Versions.POSTGRES_SOURCE, $script:Versions.POSTGRES_RUNTIME_IMAGE)
    Invoke-Docker -ArgumentList @('tag', $script:Versions.REDIS_SOURCE, $script:Versions.REDIS_RUNTIME_IMAGE)
    Invoke-Docker -ArgumentList @('tag', $script:Versions.CADDY_SOURCE, $script:Versions.CADDY_RUNTIME_IMAGE)

    $buildContext = Join-Path ([IO.Path]::GetTempPath()) "inventree-plugin-build-$([Guid]::NewGuid().ToString('N'))"
    try {
        New-Item -ItemType Directory -Path (Join-Path $buildContext 'cache') -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $script:ScriptDirectory 'Dockerfile') -Destination (Join-Path $buildContext 'Dockerfile')
        Copy-Item -LiteralPath $pluginSource -Destination (Join-Path $buildContext 'cache\plugin-source.tar.gz')

        Write-Step "Building InvenTree with plugins $($script:Versions.PLUGIN_VERSION) and $($script:Versions.STOCK_PLUGIN_VERSION)"
        Invoke-Docker -ArgumentList @(
            'build',
            '--platform', 'linux/amd64',
            '--build-arg', "INVENTREE_BASE_SOURCE=$($script:Versions.INVENTREE_BASE_SOURCE)",
            '--build-arg', "PLUGIN_ARCHIVE_SHA256=$($script:Versions.PLUGIN_ARCHIVE_SHA256)",
            '--build-arg', "PLUGIN_ARCHIVE_SUBDIRECTORY=$($script:Versions.PLUGIN_ARCHIVE_SUBDIRECTORY)",
            '--build-arg', "PLUGIN_VERSION=$($script:Versions.PLUGIN_VERSION)",
            '--build-arg', "STOCK_PLUGIN_ARCHIVE_SUBDIRECTORY=$($script:Versions.STOCK_PLUGIN_ARCHIVE_SUBDIRECTORY)",
            '--build-arg', "STOCK_PLUGIN_VERSION=$($script:Versions.STOCK_PLUGIN_VERSION)",
            '--tag', $script:Versions.INVENTREE_RUNTIME_IMAGE,
            $buildContext
        )
    }
    finally {
        if (Test-Path -LiteralPath $buildContext -PathType Container) {
            Remove-Item -LiteralPath $buildContext -Recurse -Force
        }
    }

    foreach ($image in @(
        $script:Versions.INVENTREE_RUNTIME_IMAGE,
        $script:Versions.POSTGRES_RUNTIME_IMAGE,
        $script:Versions.REDIS_RUNTIME_IMAGE,
        $script:Versions.CADDY_RUNTIME_IMAGE
    )) {
        Assert-ImagePlatform -Reference $image
    }
    Assert-PluginImageVersions -Reference $script:Versions.INVENTREE_RUNTIME_IMAGE
    Set-DeploymentImageIds `
        -InventreeImage $script:Versions.INVENTREE_RUNTIME_IMAGE `
        -PostgresImage $script:Versions.POSTGRES_RUNTIME_IMAGE `
        -RedisImage $script:Versions.REDIS_RUNTIME_IMAGE `
        -CaddyImage $script:Versions.CADDY_RUNTIME_IMAGE
}

function Write-BundleManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][hashtable]$ImageIds
    )

    $wslRelative = "prerequisites/windows/wsl-$($script:Versions.WSL_VERSION)-x64.msi"
    $dockerRelative = "prerequisites/windows/DockerDesktop-$($script:Versions.DOCKER_DESKTOP_VERSION)-$($script:Versions.DOCKER_DESKTOP_BUILD)-x64.exe"
    $lines = @(
        "INSTALLER_FORMAT_VERSION=$($script:Versions.INSTALLER_FORMAT_VERSION)",
        'HOST_PLATFORM=windows-amd64',
        'IMAGE_PLATFORM=linux/amd64',
        'IMAGES_ARCHIVE=images.tar',
        "INVENTREE_IMAGE=$($script:Versions.INVENTREE_RUNTIME_IMAGE)",
        "INVENTREE_IMAGE_ID=$($ImageIds.INVENTREE_IMAGE_ID)",
        "POSTGRES_IMAGE=$($script:Versions.POSTGRES_RUNTIME_IMAGE)",
        "POSTGRES_IMAGE_ID=$($ImageIds.POSTGRES_IMAGE_ID)",
        "REDIS_IMAGE=$($script:Versions.REDIS_RUNTIME_IMAGE)",
        "REDIS_IMAGE_ID=$($ImageIds.REDIS_IMAGE_ID)",
        "CADDY_IMAGE=$($script:Versions.CADDY_RUNTIME_IMAGE)",
        "CADDY_IMAGE_ID=$($ImageIds.CADDY_IMAGE_ID)",
        "PLUGIN_VERSION=$($script:Versions.PLUGIN_VERSION)",
        "STOCK_PLUGIN_VERSION=$($script:Versions.STOCK_PLUGIN_VERSION)",
        "PLUGIN_COMMIT=$($script:Versions.PLUGIN_COMMIT)",
        "TRAINING_DATASET_COMMIT=$($script:Versions.TRAINING_DATASET_COMMIT)",
        "TRAINING_DATASET_ARCHIVE_SHA256=$($script:Versions.TRAINING_DATASET_ARCHIVE_SHA256)",
        "WSL_INSTALLER=$wslRelative",
        "DOCKER_DESKTOP_INSTALLER=$dockerRelative"
    )
    Write-Utf8File -Path (Join-Path $Destination 'bundle.env') -Content (($lines -join "`n") + "`n")
}

function Get-RuntimeImageIds {
    return @{
        INVENTREE_IMAGE_ID = Get-ImageId -Reference $script:Versions.INVENTREE_RUNTIME_IMAGE
        POSTGRES_IMAGE_ID = Get-ImageId -Reference $script:Versions.POSTGRES_RUNTIME_IMAGE
        REDIS_IMAGE_ID = Get-ImageId -Reference $script:Versions.REDIS_RUNTIME_IMAGE
        CADDY_IMAGE_ID = Get-ImageId -Reference $script:Versions.CADDY_RUNTIME_IMAGE
    }
}

function Assert-RuntimeImageIds {
    param([Parameter(Mandatory = $true)][hashtable]$Expected)

    $actual = Get-RuntimeImageIds
    foreach ($key in $Expected.Keys) {
        if ($actual[$key] -ne $Expected[$key]) {
            Throw-InstallerError "Runtime image changed during bundle export: $key"
        }
    }
}

function Assert-DeploymentImageIdsPresent {
    foreach ($imageId in @(
        $script:InventreeDeployImage,
        $script:PostgresDeployImage,
        $script:RedisDeployImage,
        $script:CaddyDeployImage
    )) {
        if ([string]::IsNullOrWhiteSpace($imageId) -or $imageId -notmatch '^sha256:[a-f0-9]{64}$') {
            Throw-InstallerError 'Deployment image IDs have not been initialized safely'
        }
        $actual = Get-ImageId -Reference $imageId
        if ($actual -ne $imageId) {
            Throw-InstallerError "Deployment image is no longer available: $imageId"
        }
    }
}

function Write-BundleChecksums {
    param([Parameter(Mandatory = $true)][string]$Destination)

    $checksumPath = Join-Path $Destination 'SHA256SUMS'
    $root = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse -Force |
        Where-Object { $_.FullName -ne $checksumPath } |
        Sort-Object FullName)
    $lines = foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-InstallerError "Refusing reparse point in offline bundle: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($root.Length).TrimStart('\', '/').Replace('\', '/')
        "$(Get-Sha256 -Path $file.FullName)  ./$relative"
    }
    Write-Utf8File -Path $checksumPath -Content (($lines -join "`n") + "`n")
}

function Assert-BundleExportInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFiles
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        Throw-InstallerError "Bundle output path is not a directory: $Root"
    }

    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Throw-InstallerError "Refusing reparse-point bundle directory: $Root"
    }

    $expectedFileSet = @{}
    foreach ($relative in $ExpectedFiles) {
        $expectedFileSet[$relative.Replace('\', '/')] = $true
    }
    $expectedDirectorySet = @{
        'cache' = $true
        'prerequisites' = $true
        'prerequisites/windows' = $true
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')

    foreach ($directory in Get-ChildItem -LiteralPath $rootFull -Directory -Recurse -Force) {
        if (($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-InstallerError "Refusing reparse point in bundle output: $($directory.FullName)"
        }
        $relative = $directory.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not $expectedDirectorySet.ContainsKey($relative)) {
            Throw-InstallerError "Refusing unexpected directory in bundle output: $relative"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $rootFull -File -Recurse -Force) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-InstallerError "Refusing reparse point in bundle output: $($file.FullName)"
        }
        $relative = $file.FullName.Substring($rootFull.Length).TrimStart('\', '/').Replace('\', '/')
        if (-not $expectedFileSet.ContainsKey($relative)) {
            Throw-InstallerError "Refusing unexpected file in bundle output: $relative"
        }
    }
}

function Assert-WindowsBundleIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$ExpectedFiles
    )

    foreach ($relative in $ExpectedFiles) {
        Assert-RegularFile -Path (Resolve-BundlePath -Root $Root -RelativePath $relative)
    }

    $bundledVersions = Read-StrictKeyValueFile -Path (Join-Path $Root 'versions.env')
    if ($bundledVersions.Count -ne $script:Versions.Count) {
        Throw-InstallerError 'Existing bundle version manifest does not match this installer'
    }
    foreach ($key in $script:Versions.Keys) {
        if (-not $bundledVersions.ContainsKey($key) -or
            $bundledVersions[$key] -ne $script:Versions[$key]) {
            Throw-InstallerError "Existing bundle version manifest differs at $key"
        }
    }

    $manifest = Read-StrictKeyValueFile -Path (Join-Path $Root 'bundle.env')
    $expectedManifest = @{
        INSTALLER_FORMAT_VERSION = $script:Versions.INSTALLER_FORMAT_VERSION
        HOST_PLATFORM = 'windows-amd64'
        IMAGE_PLATFORM = 'linux/amd64'
        IMAGES_ARCHIVE = 'images.tar'
        INVENTREE_IMAGE = $script:Versions.INVENTREE_RUNTIME_IMAGE
        POSTGRES_IMAGE = $script:Versions.POSTGRES_RUNTIME_IMAGE
        REDIS_IMAGE = $script:Versions.REDIS_RUNTIME_IMAGE
        CADDY_IMAGE = $script:Versions.CADDY_RUNTIME_IMAGE
        PLUGIN_VERSION = $script:Versions.PLUGIN_VERSION
        STOCK_PLUGIN_VERSION = $script:Versions.STOCK_PLUGIN_VERSION
        PLUGIN_COMMIT = $script:Versions.PLUGIN_COMMIT
    }
    foreach ($key in $expectedManifest.Keys) {
        if (-not $manifest.ContainsKey($key) -or $manifest[$key] -ne $expectedManifest[$key]) {
            Throw-InstallerError "Existing bundle manifest differs at $key"
        }
    }
}

function Enter-ExportLock {
    $bundleParent = Split-Path -Parent $BundleDirectory
    if ([string]::IsNullOrWhiteSpace($bundleParent) -or $bundleParent -eq $BundleDirectory) {
        Throw-InstallerError 'Bundle directory must have a writable parent directory'
    }
    New-Item -ItemType Directory -Path $bundleParent -Force | Out-Null
    Assert-NoReparsePath -Path $bundleParent -Label 'Bundle parent'

    $lockPath = "$BundleDirectory.installer-export.lock"
    if (Test-Path -LiteralPath $lockPath) {
        Assert-RegularFile -Path $lockPath
    }
    try {
        return [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        Throw-InstallerError "Another bundle export appears active for $BundleDirectory"
    }
}

function Exit-ExportLock {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Handle)

    $Handle.Dispose()
}

function Export-OfflineBundle {
    param([Parameter(Mandatory = $true)][IO.FileStream]$LockHandle)

    if (-not $LockHandle.CanWrite) {
        Throw-InstallerError 'Bundle export lock is not held'
    }

    if ([string]::IsNullOrWhiteSpace($script:WslInstallerPath)) {
        Get-OnlineWslInstaller | Out-Null
    }
    $dockerInstaller = Get-OnlineDockerDesktopInstaller
    $trainingDataset = Get-TrainingDatasetOnline

    if ($BundleDirectory -eq $InstallDirectory -or $BundleDirectory -eq $script:ScriptDirectory) {
        Throw-InstallerError 'Bundle directory cannot equal the install or installer source directory'
    }

    $linuxInstaller = Join-Path $script:ScriptDirectory 'install-linux.sh'
    $readme = Join-Path $script:ScriptDirectory 'README.md'
    $wslName = "wsl-$($script:Versions.WSL_VERSION)-x64.msi"
    $dockerName = "DockerDesktop-$($script:Versions.DOCKER_DESKTOP_VERSION)-$($script:Versions.DOCKER_DESKTOP_BUILD)-x64.exe"
    $expectedFiles = @(
        'compose.yaml', 'Caddyfile', 'env.template', 'Dockerfile', 'versions.env',
        'install-windows.ps1', 'cache/plugin-source.tar.gz', 'cache/training-dataset.tar.gz',
        "prerequisites/windows/$wslName", "prerequisites/windows/$dockerName",
        'DOCKER-DESKTOP-LICENSE.txt',
        'images.tar', 'bundle.env', 'SHA256SUMS'
    )
    if (Test-Path -LiteralPath $linuxInstaller -PathType Leaf) {
        $expectedFiles += 'install-linux.sh'
    }
    if (Test-Path -LiteralPath $readme -PathType Leaf) {
        $expectedFiles += 'README.md'
    }

    $bundleParent = Split-Path -Parent $BundleDirectory
    $staging = $null
    $previous = "$BundleDirectory.previous"
    $obsolete = $null
    try {
        $exportImageIds = Get-RuntimeImageIds

        if (Test-Path -LiteralPath $previous) {
            Assert-NoReparsePath -Path $previous -Label 'Previous bundle recovery'
            Assert-BundleExportInventory -Root $previous -ExpectedFiles $expectedFiles
            $previousChecksums = Verify-BundleChecksums -Root $previous
            Assert-BundleFileInventory -Root $previous `
                -ChecksumEntries $previousChecksums -AllowedUnlistedPaths @()
            Assert-WindowsBundleIdentity -Root $previous -ExpectedFiles $expectedFiles

            if (-not (Test-Path -LiteralPath $BundleDirectory)) {
                Write-Step 'Recovering the previous complete offline bundle'
                [IO.Directory]::Move($previous, $BundleDirectory)
            }
            else {
                Assert-NoReparsePath -Path $BundleDirectory -Label 'Bundle output'
                Assert-BundleExportInventory -Root $BundleDirectory -ExpectedFiles $expectedFiles
                $currentChecksums = Verify-BundleChecksums -Root $BundleDirectory
                Assert-BundleFileInventory -Root $BundleDirectory `
                    -ChecksumEntries $currentChecksums -AllowedUnlistedPaths @()
                Assert-WindowsBundleIdentity -Root $BundleDirectory -ExpectedFiles $expectedFiles

                $obsolete = Join-Path $bundleParent ".$(Split-Path -Leaf $BundleDirectory).obsolete.$([Guid]::NewGuid().ToString('N'))"
                [IO.Directory]::Move($previous, $obsolete)
                try {
                    Remove-Item -LiteralPath $obsolete -Recurse -Force
                    $obsolete = $null
                }
                catch {
                    Write-Warning "A superseded bundle could not be fully removed: $obsolete"
                }
            }
        }

        if (Test-Path -LiteralPath $BundleDirectory) {
            Assert-NoReparsePath -Path $BundleDirectory -Label 'Bundle output'
            Assert-BundleExportInventory -Root $BundleDirectory -ExpectedFiles $expectedFiles
            if ($null -eq (Get-ChildItem -LiteralPath $BundleDirectory -Force | Select-Object -First 1)) {
                Throw-InstallerError "Refusing to replace an unrecognized empty directory: $BundleDirectory"
            }
            $existingChecksums = Verify-BundleChecksums -Root $BundleDirectory
            Assert-BundleFileInventory -Root $BundleDirectory `
                -ChecksumEntries $existingChecksums -AllowedUnlistedPaths @()
            Assert-WindowsBundleIdentity -Root $BundleDirectory -ExpectedFiles $expectedFiles
        }

        $staging = Join-Path $bundleParent ".$(Split-Path -Leaf $BundleDirectory).staging.$([Guid]::NewGuid().ToString('N'))"
        New-Item -ItemType Directory -Path (Join-Path $staging 'cache') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $staging 'prerequisites\windows') -Force | Out-Null

        Write-Step "Saving reusable Windows application bundle to $BundleDirectory"
        foreach ($asset in @('compose.yaml', 'Caddyfile', 'env.template', 'Dockerfile', 'versions.env', 'install-windows.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:ScriptDirectory $asset) -Destination (Join-Path $staging $asset)
        }
        if (Test-Path -LiteralPath $linuxInstaller -PathType Leaf) {
            Copy-Item -LiteralPath $linuxInstaller -Destination (Join-Path $staging 'install-linux.sh')
        }
        if (Test-Path -LiteralPath $readme -PathType Leaf) {
            Copy-Item -LiteralPath $readme -Destination (Join-Path $staging 'README.md')
        }
        Copy-Item -LiteralPath (Join-Path $script:ScriptDirectory 'cache\plugin-source.tar.gz') `
            -Destination (Join-Path $staging 'cache\plugin-source.tar.gz')
        Copy-Item -LiteralPath $trainingDataset `
            -Destination (Join-Path $staging 'cache\training-dataset.tar.gz')

        Copy-Item -LiteralPath $script:WslInstallerPath `
            -Destination (Join-Path $staging "prerequisites\windows\$wslName")
        Copy-Item -LiteralPath $dockerInstaller `
            -Destination (Join-Path $staging "prerequisites\windows\$dockerName")

        $notice = @"
This bundle retains the official pinned Docker Desktop installer downloaded
from:
$($script:Versions.DOCKER_DESKTOP_URL)

The offline installer verifies its pinned SHA-256 hash and Docker Inc.
Authenticode signature before use. Review and accept Docker's terms before
installing it on the target machine.

Retaining this installer is intended only for licensed internal reuse. Do not
publish or otherwise redistribute this bundle without Docker's permission.
Docker terms: https://www.docker.com/legal/docker-subscription-service-agreement/
"@
        Write-Utf8File -Path (Join-Path $staging 'DOCKER-DESKTOP-LICENSE.txt') -Content $notice

        $imagesArchive = Join-Path $staging 'images.tar'
        Invoke-Docker -ArgumentList @(
            'image', 'save', '--output', $imagesArchive,
            $exportImageIds.INVENTREE_IMAGE_ID,
            $exportImageIds.POSTGRES_IMAGE_ID,
            $exportImageIds.REDIS_IMAGE_ID,
            $exportImageIds.CADDY_IMAGE_ID
        )
        Assert-RuntimeImageIds -Expected $exportImageIds
        Write-BundleManifest -Destination $staging -ImageIds $exportImageIds
        Write-BundleChecksums -Destination $staging
        Assert-BundleExportInventory -Root $staging -ExpectedFiles $expectedFiles
        foreach ($relative in $expectedFiles) {
            Assert-RegularFile -Path (Resolve-BundlePath -Root $staging -RelativePath $relative)
        }
        $stagingChecksums = Verify-BundleChecksums -Root $staging
        Assert-BundleFileInventory -Root $staging `
            -ChecksumEntries $stagingChecksums -AllowedUnlistedPaths @()
        Assert-WindowsBundleIdentity -Root $staging -ExpectedFiles $expectedFiles

        if (Test-Path -LiteralPath $BundleDirectory) {
            [IO.Directory]::Move($BundleDirectory, $previous)
        }
        try {
            [IO.Directory]::Move($staging, $BundleDirectory)
            $staging = $null
        }
        catch {
            if ((Test-Path -LiteralPath $previous -PathType Container) -and
                -not (Test-Path -LiteralPath $BundleDirectory)) {
                [IO.Directory]::Move($previous, $BundleDirectory)
            }
            throw
        }

        if (Test-Path -LiteralPath $previous -PathType Container) {
            try {
                $obsolete = Join-Path $bundleParent ".$(Split-Path -Leaf $BundleDirectory).obsolete.$([Guid]::NewGuid().ToString('N'))"
                [IO.Directory]::Move($previous, $obsolete)
                Remove-Item -LiteralPath $obsolete -Recurse -Force
                $obsolete = $null
            }
            catch {
                Write-Warning "The new bundle is complete, but the previous bundle could not be fully removed: $obsolete"
            }
        }
    }
    finally {
        if ($null -ne $staging -and (Test-Path -LiteralPath $staging -PathType Container)) {
            try {
                Assert-NoReparsePath -Path $staging -Label 'Bundle staging'
                Remove-Item -LiteralPath $staging -Recurse -Force
            }
            catch {
                Write-Warning "Could not safely remove incomplete bundle staging directory: $staging"
            }
        }
    }
}

function Initialize-OfflineBundle {
    Assert-NoReparseTree -Root $OfflineBundle -Label 'Offline bundle'
    $checksumEntries = Verify-BundleChecksums -Root $OfflineBundle
    $script:Versions = Read-StrictKeyValueFile -Path (Join-Path $OfflineBundle 'versions.env')
    Assert-VersionManifest
    $script:Bundle = Read-StrictKeyValueFile -Path (Join-Path $OfflineBundle 'bundle.env')
    $bundleKeys = @(
        'INSTALLER_FORMAT_VERSION', 'HOST_PLATFORM', 'IMAGE_PLATFORM', 'IMAGES_ARCHIVE',
        'INVENTREE_IMAGE', 'INVENTREE_IMAGE_ID', 'POSTGRES_IMAGE', 'POSTGRES_IMAGE_ID',
        'REDIS_IMAGE', 'REDIS_IMAGE_ID', 'CADDY_IMAGE', 'CADDY_IMAGE_ID',
        'PLUGIN_VERSION', 'STOCK_PLUGIN_VERSION', 'PLUGIN_COMMIT',
        'TRAINING_DATASET_COMMIT', 'TRAINING_DATASET_ARCHIVE_SHA256',
        'WSL_INSTALLER', 'DOCKER_DESKTOP_INSTALLER'
    )
    Assert-RequiredKeys -Values $script:Bundle -SourceName 'bundle.env' -Keys $bundleKeys
    Assert-OnlyKeys -Values $script:Bundle -SourceName 'bundle.env' -Keys $bundleKeys

    if ($script:Bundle.INSTALLER_FORMAT_VERSION -ne $script:Versions.INSTALLER_FORMAT_VERSION) {
        Throw-InstallerError 'Unsupported offline bundle format version'
    }
    if ($script:Bundle.HOST_PLATFORM -ne 'windows-amd64' -or $script:Bundle.IMAGE_PLATFORM -ne 'linux/amd64') {
        Throw-InstallerError "Offline bundle platform does not match Windows x86-64 with Linux containers"
    }
    if ($script:Bundle.PLUGIN_VERSION -ne $script:Versions.PLUGIN_VERSION -or
        $script:Bundle.STOCK_PLUGIN_VERSION -ne $script:Versions.STOCK_PLUGIN_VERSION -or
        $script:Bundle.PLUGIN_COMMIT -ne $script:Versions.PLUGIN_COMMIT) {
        Throw-InstallerError 'Offline bundle plugin metadata does not match versions.env'
    }
    if ($script:Bundle.TRAINING_DATASET_COMMIT -ne $script:Versions.TRAINING_DATASET_COMMIT -or
        $script:Bundle.TRAINING_DATASET_ARCHIVE_SHA256 -ne $script:Versions.TRAINING_DATASET_ARCHIVE_SHA256) {
        Throw-InstallerError 'Offline bundle training dataset metadata does not match versions.env'
    }

    $comparisons = @{
        INVENTREE_IMAGE = 'INVENTREE_RUNTIME_IMAGE'
        POSTGRES_IMAGE = 'POSTGRES_RUNTIME_IMAGE'
        REDIS_IMAGE = 'REDIS_RUNTIME_IMAGE'
        CADDY_IMAGE = 'CADDY_RUNTIME_IMAGE'
    }
    foreach ($bundleKey in $comparisons.Keys) {
        $versionKey = $comparisons[$bundleKey]
        if ($script:Bundle[$bundleKey] -ne $script:Versions[$versionKey]) {
            Throw-InstallerError "Offline bundle image '$bundleKey' does not match versions.env"
        }
    }

    foreach ($coveredPath in @($script:Bundle.IMAGES_ARCHIVE, $script:Bundle.WSL_INSTALLER, $script:Bundle.DOCKER_DESKTOP_INSTALLER, 'cache/plugin-source.tar.gz', 'cache/training-dataset.tar.gz')) {
        if (-not $checksumEntries.ContainsKey($coveredPath)) {
            Throw-InstallerError "SHA256SUMS does not cover required bundle file: $coveredPath"
        }
    }
    Assert-BundleFileInventory -Root $OfflineBundle -ChecksumEntries $checksumEntries `
        -AllowedUnlistedPaths @()
    $suppliedDockerInstaller = Resolve-BundlePath -Root $OfflineBundle -RelativePath $script:Bundle.DOCKER_DESKTOP_INSTALLER
    Assert-RegularFile -Path $suppliedDockerInstaller
    if ((Get-Sha256 -Path $suppliedDockerInstaller) -ne $script:Versions.DOCKER_DESKTOP_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Bundled Docker Desktop installer SHA-256 mismatch'
    }
    Assert-AuthenticodePublisher -Path $suppliedDockerInstaller -PublisherPattern 'Docker Inc'
    $script:AssetRoot = $OfflineBundle
}

function Verify-LoadedImage {
    param(
        [Parameter(Mandatory = $true)][string]$Reference,
        [Parameter(Mandatory = $true)][string]$ExpectedId
    )

    $actualId = Get-ImageId -Reference $Reference
    if ($actualId -ne $ExpectedId) {
        Throw-InstallerError "Loaded image ID mismatch for $Reference"
    }
    Assert-ImagePlatform -Reference $Reference
}

function Load-OfflineImages {
    $archive = Resolve-BundlePath -Root $OfflineBundle -RelativePath $script:Bundle.IMAGES_ARCHIVE
    Write-Step 'Loading cached application images'
    Invoke-Docker -ArgumentList @('image', 'load', '--input', $archive)

    Verify-LoadedImage -Reference $script:Bundle.INVENTREE_IMAGE_ID -ExpectedId $script:Bundle.INVENTREE_IMAGE_ID
    Verify-LoadedImage -Reference $script:Bundle.POSTGRES_IMAGE_ID -ExpectedId $script:Bundle.POSTGRES_IMAGE_ID
    Verify-LoadedImage -Reference $script:Bundle.REDIS_IMAGE_ID -ExpectedId $script:Bundle.REDIS_IMAGE_ID
    Verify-LoadedImage -Reference $script:Bundle.CADDY_IMAGE_ID -ExpectedId $script:Bundle.CADDY_IMAGE_ID
    Assert-PluginImageVersions -Reference $script:Bundle.INVENTREE_IMAGE_ID

    $script:InventreeDeployImage = $script:Bundle.INVENTREE_IMAGE_ID
    $script:PostgresDeployImage = $script:Bundle.POSTGRES_IMAGE_ID
    $script:RedisDeployImage = $script:Bundle.REDIS_IMAGE_ID
    $script:CaddyDeployImage = $script:Bundle.CADDY_IMAGE_ID
}

function Assert-VersionManifest {
    $requiredKeys = @(
        'INSTALLER_FORMAT_VERSION', 'INVENTREE_BASE_SOURCE', 'INVENTREE_RUNTIME_IMAGE',
        'POSTGRES_SOURCE', 'POSTGRES_RUNTIME_IMAGE', 'REDIS_SOURCE', 'REDIS_RUNTIME_IMAGE',
        'CADDY_SOURCE', 'CADDY_RUNTIME_IMAGE', 'PLUGIN_VERSION', 'PLUGIN_COMMIT',
        'PLUGIN_ARCHIVE_URL', 'PLUGIN_ARCHIVE_SHA256', 'PLUGIN_ARCHIVE_SUBDIRECTORY',
        'STOCK_PLUGIN_VERSION', 'STOCK_PLUGIN_ARCHIVE_SUBDIRECTORY',
        'TRAINING_DATASET_COMMIT', 'TRAINING_DATASET_ARCHIVE_URL',
        'TRAINING_DATASET_ARCHIVE_SHA256', 'TRAINING_USD_IRT_RATE',
        'DOCKER_DESKTOP_VERSION',
        'DOCKER_DESKTOP_BUILD', 'DOCKER_DESKTOP_URL', 'DOCKER_DESKTOP_SHA256',
        'WSL_VERSION', 'WSL_URL', 'WSL_SHA256'
    )
    $allowedKeys = $requiredKeys + @('PLUGIN_ARCHIVE_NAME', 'TRAINING_DATASET_ARCHIVE_NAME')
    Assert-RequiredKeys -Values $script:Versions -SourceName 'versions.env' -Keys $requiredKeys
    Assert-OnlyKeys -Values $script:Versions -SourceName 'versions.env' -Keys $allowedKeys
    foreach ($hashKey in @('PLUGIN_ARCHIVE_SHA256', 'TRAINING_DATASET_ARCHIVE_SHA256', 'DOCKER_DESKTOP_SHA256', 'WSL_SHA256')) {
        if ($script:Versions[$hashKey] -notmatch '^[a-fA-F0-9]{64}$') {
            Throw-InstallerError "Invalid SHA-256 value in versions.env: $hashKey"
        }
    }
    foreach ($urlKey in @('PLUGIN_ARCHIVE_URL', 'TRAINING_DATASET_ARCHIVE_URL', 'DOCKER_DESKTOP_URL', 'WSL_URL')) {
        if ($script:Versions[$urlKey] -notmatch '^https://') {
            Throw-InstallerError "Only HTTPS URLs are allowed in versions.env: $urlKey"
        }
    }
    $trainingRate = 0.0
    if (-not [double]::TryParse(
        $script:Versions.TRAINING_USD_IRT_RATE,
        [Globalization.NumberStyles]::AllowDecimalPoint,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$trainingRate
    ) -or $trainingRate -le 0) {
        Throw-InstallerError 'TRAINING_USD_IRT_RATE must be a positive number'
    }
}

function New-RandomPassword {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Protect-SecretFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-RegularFile -Path $Path
    $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $owner) {
        Throw-InstallerError "Could not determine the owner for secret file: $Path"
    }

    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sidValue in @($owner.Value, 'S-1-5-18', 'S-1-5-32-544')) {
        $sid = [Security.Principal.SecurityIdentifier]::new($sidValue)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $sid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Write-ProtectedFileTransactionally {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$Content
    )

    $parent = Split-Path -Parent $Destination
    $leaf = Split-Path -Leaf $Destination
    $temporary = Join-Path $parent ".$leaf.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.File]::Open(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        Protect-SecretFile -Path $temporary
        Write-Utf8File -Path $temporary -Content $Content
        if (Test-Path -LiteralPath $Destination) {
            Assert-RegularFile -Path $Destination
            [IO.File]::Replace($temporary, $Destination, $null)
        }
        else {
            [IO.File]::Move($temporary, $Destination)
        }
        $temporary = $null
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($temporary) -and
            (Test-Path -LiteralPath $temporary -PathType Leaf)) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Copy-IfMissing {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    Assert-RegularFile -Path $Source
    if (Test-Path -LiteralPath $Destination) {
        Assert-RegularFile -Path $Destination
        if ((Get-Sha256 -Path $Source) -ne (Get-Sha256 -Path $Destination)) {
            Throw-InstallerError "Existing $Destination differs from this installer. Move it aside explicitly or choose a new install directory."
        }
        return
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}

function Enter-InstallLock {
    New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    $lockPath = Join-Path $InstallDirectory '.installer.lock'
    if (Test-Path -LiteralPath $lockPath) {
        Assert-RegularFile -Path $lockPath
    }

    try {
        $handle = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        Throw-InstallerError "Another installer process appears active for $InstallDirectory"
    }

    $details = "PID=$PID`nSTARTED_AT=$([DateTime]::UtcNow.ToString('o'))`n"
    $bytes = $script:Utf8NoBom.GetBytes($details)
    $handle.SetLength(0)
    $handle.Write($bytes, 0, $bytes.Length)
    $handle.Flush()
    return $handle
}

function Exit-InstallLock {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Handle)

    $lockPath = Join-Path $InstallDirectory '.installer.lock'
    $Handle.Dispose()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}

function Assert-PluginIntegrationSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$SourceName
    )

    try {
        $integrationSettings = $Value | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Throw-InstallerError "$SourceName has invalid INVENTREE_GLOBAL_SETTINGS JSON"
    }

    $invalidSettings = [System.Collections.Generic.List[string]]::new()
    foreach ($key in @(
        'ENABLE_PLUGINS_APP',
        'ENABLE_PLUGINS_URL',
        'ENABLE_PLUGINS_INTERFACE',
        'ENABLE_PLUGINS_SCHEDULE'
    )) {
        if ($integrationSettings.$key -ne $true) {
            $invalidSettings.Add($key)
        }
    }

    $currencyCodes = @()
    if ($null -ne $integrationSettings.CURRENCY_CODES) {
        $currencyCodes = @(
            $integrationSettings.CURRENCY_CODES.ToString().Split(',') |
                ForEach-Object { $_.Trim().ToUpperInvariant() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    if ($currencyCodes -notcontains 'USD' -or $currencyCodes -notcontains 'IRT') {
        $invalidSettings.Add('CURRENCY_CODES')
    }
    if ($integrationSettings.INVENTREE_DEFAULT_CURRENCY -ne 'USD') {
        $invalidSettings.Add('INVENTREE_DEFAULT_CURRENCY')
    }
    if ($integrationSettings.CURRENCY_UPDATE_PLUGIN -ne 'inventree-usd-irt-exchange-rate') {
        $invalidSettings.Add('CURRENCY_UPDATE_PLUGIN')
    }
    if ($integrationSettings.CURRENCY_UPDATE_INTERVAL -ne 0) {
        $invalidSettings.Add('CURRENCY_UPDATE_INTERVAL')
    }

    if ($invalidSettings.Count -gt 0) {
        Throw-InstallerError "$SourceName lacks required currency/plugin integration settings: $($invalidSettings -join ', '). Enable App, URL, Interface, and Schedule integration while preserving custom settings, then rerun."
    }
}

function Prepare-DeploymentFiles {
    Assert-DeploymentImageIdsPresent

    $currencyPluginSlug = 'inventree-usd-irt-exchange-rate'
    $stockPluginSlug = 'inventree-stock-xlsx-adjustment'
    $installerMandatoryPlugins = "$currencyPluginSlug,$stockPluginSlug"
    $legacyGlobalSettings = '{"INVENTREE_DEFAULT_CURRENCY":"USD","CURRENCY_CODES":"USD,IRT","CURRENCY_UPDATE_PLUGIN":"inventree-usd-irt-exchange-rate","CURRENCY_UPDATE_INTERVAL":0,"INVENTREE_UPDATE_CHECK_INTERVAL":0,"ENABLE_PLUGINS_SCHEDULE":true,"PLUGIN_ON_STARTUP":false,"INVENTREE_BACKUP_ENABLE":true,"INVENTREE_BACKUP_DAYS":1}'

    $templatePath = Join-Path $script:AssetRoot 'env.template'
    Assert-RegularFile -Path $templatePath
    $templateEnvironment = Read-StrictKeyValueFile -Path $templatePath
    if (-not $templateEnvironment.ContainsKey('INVENTREE_PLUGINS_MANDATORY') -or
        $templateEnvironment.INVENTREE_PLUGINS_MANDATORY -cne $installerMandatoryPlugins) {
        Throw-InstallerError "env.template must set INVENTREE_PLUGINS_MANDATORY=$installerMandatoryPlugins"
    }
    if (-not $templateEnvironment.ContainsKey('INVENTREE_GLOBAL_SETTINGS')) {
        Throw-InstallerError 'env.template must define INVENTREE_GLOBAL_SETTINGS'
    }
    $installerGlobalSettings = $templateEnvironment.INVENTREE_GLOBAL_SETTINGS
    Assert-PluginIntegrationSettings -Value $installerGlobalSettings -SourceName 'env.template'

    Assert-RealDirectory -Path $InstallDirectory -Label 'Install directory' -Create
    $dataDirectory = Join-Path $InstallDirectory 'inventree-data'
    Assert-RealDirectory -Path $dataDirectory -Label 'InvenTree data directory' -Create
    foreach ($relative in @('database', 'static', 'media', 'caddy', 'caddy\data', 'caddy\config')) {
        $child = Join-Path $dataDirectory $relative
        Assert-RealDirectory -Path $child -Label "InvenTree bind-mount directory '$relative'" -Create
    }
    Copy-IfMissing -Source (Join-Path $script:AssetRoot 'compose.yaml') -Destination (Join-Path $InstallDirectory 'compose.yaml')
    Copy-IfMissing -Source (Join-Path $script:AssetRoot 'Caddyfile') -Destination (Join-Path $InstallDirectory 'Caddyfile')

    $environmentPath = Join-Path $InstallDirectory '.env'
    if (Test-Path -LiteralPath $environmentPath) {
        Assert-RegularFile -Path $environmentPath
        Protect-SecretFile -Path $environmentPath
        Write-Step "Checking existing $environmentPath"
        $environment = Read-StrictKeyValueFile -Path $environmentPath
        $expected = @{
            INVENTREE_IMAGE = $script:InventreeDeployImage
            INVENTREE_DB_IMAGE = $script:PostgresDeployImage
            INVENTREE_CACHE_IMAGE = $script:RedisDeployImage
            INVENTREE_PROXY_IMAGE = $script:CaddyDeployImage
        }
        $legacy = @{
            INVENTREE_IMAGE = $script:Versions.INVENTREE_RUNTIME_IMAGE
            INVENTREE_DB_IMAGE = $script:Versions.POSTGRES_RUNTIME_IMAGE
            INVENTREE_CACHE_IMAGE = $script:Versions.REDIS_RUNTIME_IMAGE
            INVENTREE_PROXY_IMAGE = $script:Versions.CADDY_RUNTIME_IMAGE
        }
        $migrateImageReferences = $false
        foreach ($key in $expected.Keys) {
            if (-not $environment.ContainsKey($key)) {
                Throw-InstallerError "Existing .env does not select this bundle's $key. Update it explicitly or use a new install directory."
            }
            if ($environment[$key] -eq $legacy[$key]) {
                $migrateImageReferences = $true
            }
            elseif ($environment[$key] -ne $expected[$key]) {
                Throw-InstallerError "Existing .env does not select this bundle's $key. Update it explicitly or use a new install directory."
            }
        }

        if (-not $environment.ContainsKey('INVENTREE_PLUGINS_MANDATORY')) {
            Throw-InstallerError "Existing .env must set INVENTREE_PLUGINS_MANDATORY to include '$currencyPluginSlug' and '$stockPluginSlug'. Add both plugins without removing any custom entries, then rerun."
        }
        $mandatoryPlugins = @(
            $environment.INVENTREE_PLUGINS_MANDATORY.Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        $migrateMandatoryPlugins = $false
        if ($environment.INVENTREE_PLUGINS_MANDATORY -ceq $currencyPluginSlug) {
            $migrateMandatoryPlugins = $true
        }
        elseif ($mandatoryPlugins -notcontains $currencyPluginSlug -or
            $mandatoryPlugins -notcontains $stockPluginSlug) {
            Throw-InstallerError "Existing .env has a custom INVENTREE_PLUGINS_MANDATORY list which does not include '$currencyPluginSlug' and '$stockPluginSlug'. Add both without removing custom entries, then rerun; the installer has not changed the file."
        }

        if (-not $environment.ContainsKey('INVENTREE_GLOBAL_SETTINGS')) {
            Throw-InstallerError 'Existing .env must define INVENTREE_GLOBAL_SETTINGS'
        }
        $migrateIntegrationSettings = $environment.INVENTREE_GLOBAL_SETTINGS -ceq $legacyGlobalSettings
        if (-not $migrateIntegrationSettings) {
            Assert-PluginIntegrationSettings `
                -Value $environment.INVENTREE_GLOBAL_SETTINGS `
                -SourceName 'Existing .env'
        }

        if ($migrateImageReferences -or $migrateMandatoryPlugins -or $migrateIntegrationSettings) {
            Write-Step 'Updating installer-owned deployment settings'
            $updatedLines = foreach ($line in [IO.File]::ReadAllLines($environmentPath)) {
                if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
                    $environmentKey = $Matches[1]
                    if ($migrateImageReferences -and $expected.ContainsKey($environmentKey)) {
                        "$environmentKey=$($expected[$environmentKey])"
                    }
                    elseif ($migrateMandatoryPlugins -and
                        $environmentKey -eq 'INVENTREE_PLUGINS_MANDATORY') {
                        "INVENTREE_PLUGINS_MANDATORY=$installerMandatoryPlugins"
                    }
                    elseif ($migrateIntegrationSettings -and
                        $environmentKey -eq 'INVENTREE_GLOBAL_SETTINGS') {
                        "INVENTREE_GLOBAL_SETTINGS=$installerGlobalSettings"
                    }
                    else {
                        $line
                    }
                }
                else {
                    $line
                }
            }
            Write-ProtectedFileTransactionally `
                -Destination $environmentPath `
                -Content (($updatedLines -join "`n") + "`n")
        }
        if (-not $environment.ContainsKey('INVENTREE_HTTP_PORT') -or
            $environment.INVENTREE_HTTP_PORT -notmatch '^\d+$') {
            Throw-InstallerError 'Existing .env has no valid INVENTREE_HTTP_PORT'
        }
        $configuredPort = 0
        if (-not [int]::TryParse($environment.INVENTREE_HTTP_PORT, [ref]$configuredPort) -or
            $configuredPort -lt 1 -or $configuredPort -gt 65535) {
            Throw-InstallerError 'Existing .env has no valid INVENTREE_HTTP_PORT'
        }
        if ($configuredPort -ne $HttpPort) {
            Throw-InstallerError "Existing .env uses HTTP port $configuredPort; rerun with -HttpPort $configuredPort."
        }
        $script:EffectiveHttpPort = $configuredPort
    }
    else {
        $content = [IO.File]::ReadAllText($templatePath)
        $content = $content.Replace('__INVENTREE_IMAGE__', $script:InventreeDeployImage)
        $content = $content.Replace('__POSTGRES_IMAGE__', $script:PostgresDeployImage)
        $content = $content.Replace('__REDIS_IMAGE__', $script:RedisDeployImage)
        $content = $content.Replace('__CADDY_IMAGE__', $script:CaddyDeployImage)
        $content = $content.Replace('__HTTP_PORT__', $HttpPort.ToString())
        $content = $content.Replace('__DB_PASSWORD__', (New-RandomPassword))
        Write-ProtectedFileTransactionally -Destination $environmentPath -Content $content
        $script:EffectiveHttpPort = $HttpPort
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [Parameter()][switch]$CaptureOutput
    )

    $arguments = @(
        'compose',
        '--project-directory', $InstallDirectory,
        '--file', (Join-Path $InstallDirectory 'compose.yaml'),
        '--env-file', (Join-Path $InstallDirectory '.env')
    ) + $ArgumentList
    if ($CaptureOutput) {
        return Invoke-Docker -ArgumentList $arguments -CaptureOutput
    }
    Invoke-Docker -ArgumentList $arguments
}

function Test-ComposeCommand {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)

    $arguments = @(
        'compose',
        '--project-directory', $InstallDirectory,
        '--file', (Join-Path $InstallDirectory 'compose.yaml'),
        '--env-file', (Join-Path $InstallDirectory '.env')
    ) + $ArgumentList
    return Test-NativeCommand -FilePath $script:DockerCommand -ArgumentList $arguments
}

function Get-ExistingAdminCount {
    $output = Invoke-Compose -ArgumentList @(
        'run', '--rm', '--no-deps', '--entrypoint', 'python', 'inventree-server',
        'src/backend/InvenTree/manage.py', 'shell', '-c',
        'from django.contrib.auth import get_user_model; print(get_user_model().objects.filter(is_superuser=True).count())'
    ) -CaptureOutput
    $lastLine = Get-LastOutputLine -Output $output
    if ($lastLine -notmatch '^\d+$') {
        Throw-InstallerError "Could not determine existing administrator count: $lastLine"
    }
    return [int]$lastLine
}

function Test-TrainingDatabaseEmpty {
    $output = Invoke-Compose -ArgumentList @(
        'run', '--rm', '--no-deps', '--entrypoint', 'python', 'inventree-server',
        'src/backend/InvenTree/manage.py', 'shell', '-c',
        "from django.apps import apps; from django.contrib.auth import get_user_model; labels = ('part.Part', 'stock.StockItem', 'company.Company', 'build.Build', 'order.PurchaseOrder', 'order.SalesOrder', 'order.ReturnOrder', 'order.TransferOrder'); models = (apps.get_model(label) for label in labels); print('nonempty' if get_user_model().objects.exists() or any(model.objects.exists() for model in models) else 'empty')"
    ) -CaptureOutput
    $state = Get-LastOutputLine -Output $output
    if ($state -notin @('empty', 'nonempty')) {
        Throw-InstallerError "Could not determine whether the training database is empty: $state"
    }
    return $state -eq 'empty'
}

function Import-TrainingData {
    $sourceArchive = Join-Path $script:AssetRoot 'cache\training-dataset.tar.gz'
    Assert-RegularFile -Path $sourceArchive
    if ((Get-Sha256 -Path $sourceArchive) -ne $script:Versions.TRAINING_DATASET_ARCHIVE_SHA256.ToLowerInvariant()) {
        Throw-InstallerError 'Training dataset SHA-256 mismatch'
    }
    if (-not (Test-TrainingDatabaseEmpty)) {
        Throw-InstallerError '-TrainingData is only allowed for a new empty database; existing data was not changed'
    }

    $dataDirectory = Join-Path $InstallDirectory 'inventree-data'
    $temporaryArchive = Join-Path $dataDirectory ".training-dataset.$([Guid]::NewGuid().ToString('N')).tar.gz"
    try {
        [IO.File]::Copy($sourceArchive, $temporaryArchive, $false)
        if ((Get-Sha256 -Path $temporaryArchive) -ne $script:Versions.TRAINING_DATASET_ARCHIVE_SHA256.ToLowerInvariant()) {
            Throw-InstallerError 'Copied training dataset SHA-256 mismatch'
        }

        Write-Step 'Importing comprehensive official InvenTree training data'
        Invoke-Compose -ArgumentList @(
            'run', '--rm', '--entrypoint', 'sh', 'inventree-server',
            '-ceu',
            'training_dir="$(mktemp -d)"; cleanup_training_dir() { rm -rf -- "$training_dir"; }; trap cleanup_training_dir EXIT; tar -xzf "/home/inventree/data/$1" --strip-components=1 -C "$training_dir"; test -f "$training_dir/inventree_data.json"; test -d "$training_dir/media"; cp -a "$training_dir/media/." /home/inventree/data/media/; invoke import-records --ignore-nonexistent -c -f "$training_dir/inventree_data.json"',
            '--', (Split-Path -Leaf $temporaryArchive)
        )
    }
    finally {
        if (Test-Path -LiteralPath $temporaryArchive -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryArchive -Force
        }
    }
}

function Initialize-TrainingCurrency {
    $rate = $script:Versions.TRAINING_USD_IRT_RATE
    Invoke-Compose -ArgumentList @(
        'run', '--rm', '--entrypoint', 'python', 'inventree-server',
        'src/backend/InvenTree/manage.py', 'shell', '-c',
        "from decimal import Decimal; from djmoney.contrib.exchange.models import Rate; from InvenTree.tasks import update_exchange_rates; from plugin.registry import registry; plugin = registry.get_plugin('inventree-usd-irt-exchange-rate'); assert plugin, 'USD/IRT plugin is not active'; plugin.set_setting('API_ENABLED', False); plugin.set_setting('USD_IRT_RATE', '$rate'); update_exchange_rates(force=True); rates = {row.currency: row.value for row in Rate.objects.filter(backend='InvenTreeExchange')}; assert rates.get('USD') == Decimal('1') and rates.get('IRT') == Decimal('$rate'), 'Training exchange rates were not initialized'"
    )
}

function Assert-TrainingData {
    $output = Invoke-Compose -ArgumentList @(
        'exec', '-T', 'inventree-server', 'python', 'src/backend/InvenTree/manage.py', 'shell', '-c',
        "from django.apps import apps; from django.contrib.auth import get_user_model; expected = {'part.Part': 438, 'stock.StockItem': 1278, 'part.BomItem': 268, 'part.BomItemSubstitute': 4, 'company.Company': 41, 'company.SupplierPart': 780, 'build.Build': 28, 'order.PurchaseOrder': 20, 'order.SalesOrder': 14, 'order.ReturnOrder': 7, 'order.TransferOrder': 5}; actual = {label: apps.get_model(label).objects.count() for label in expected}; assert actual == expected, f'Training record counts do not match: {actual}'; User = get_user_model(); passwords = {'admin': 'inventree', 'allaccess': 'nolimits', 'reader': 'readonly', 'engineer': 'partsonly'}; assert all(User.objects.get(username=name).check_password(password) for name, password in passwords.items()), 'Training accounts are invalid'; print('ok')"
    ) -CaptureOutput
    if ((Get-LastOutputLine -Output $output) -ne 'ok') {
        Throw-InstallerError 'Training dataset verification failed'
    }
}

function Wait-ForApplicationHealth {
    $uri = "http://localhost:$($script:EffectiveHttpPort)/api/system/health/"
    $deadline = (Get-Date).AddMinutes(5)
    do {
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 5
            $payload = $response.Content | ConvertFrom-Json
            if ($response.StatusCode -eq 200 -and $payload.status -eq 'ok') {
                return
            }
        }
        catch {
            # The service may still be starting.
        }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)

    Throw-InstallerError "InvenTree health endpoint did not become ready: $uri"
}

function Deploy-Application {
    $pluginVersionCommand = "import importlib.metadata as m; print(m.version('inventree-usd-irt-exchange-rate') + '|' + m.version('inventree-stock-xlsx-adjustment'))"
    $expectedPluginVersions = "$($script:Versions.PLUGIN_VERSION)|$($script:Versions.STOCK_PLUGIN_VERSION)"

    $markerPath = Join-Path $InstallDirectory '.installed'
    if ($TrainingData -and (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Throw-InstallerError '-TrainingData is only allowed during the first installation; existing data was not changed'
    }

    Write-Step 'Validating deployment configuration'
    Invoke-Compose -ArgumentList @('config', '--quiet')

    Write-Step 'Stopping application processes before migration'
    Invoke-Compose -ArgumentList @('stop', 'inventree-proxy', 'inventree-worker', 'inventree-server')

    Write-Step 'Starting database and cache'
    Invoke-Compose -ArgumentList @('up', '-d', '--pull', 'never', '--no-build', 'inventree-db', 'inventree-cache')

    $imageCheck = Invoke-Compose -ArgumentList @(
        'run', '--rm', '--no-deps', '--entrypoint', 'python', 'inventree-server', '-c',
        $pluginVersionCommand
    ) -CaptureOutput
    if ((Get-LastOutputLine -Output $imageCheck) -ne $expectedPluginVersions) {
        Throw-InstallerError 'Deployment image does not contain the expected plugin versions'
    }

    if (Test-Path -LiteralPath $markerPath) {
        Assert-RegularFile -Path $markerPath
        Protect-SecretFile -Path $markerPath
        Write-Step 'Backing up the existing InvenTree database and media'
        Invoke-Compose -ArgumentList @('run', '--rm', 'inventree-server', 'invoke', 'backup')
    }

    Write-Step 'Applying database migrations'
    Invoke-Compose -ArgumentList @('run', '--rm', 'inventree-server', 'invoke', 'migrate')
    if ($TrainingData) {
        Import-TrainingData
    }
    Write-Step 'Registering mandatory plugins and applying plugin-app migrations'
    Invoke-Compose -ArgumentList @(
        'run', '--rm', '--entrypoint', 'python', 'inventree-server',
        'src/backend/InvenTree/manage.py', 'shell', '-c',
        "from django.utils.text import slugify; from plugin.models import PluginConfig; from plugin.registry import registry; tuple(PluginConfig.objects.get_or_create(key=slugify(module.SLUG if getattr(module, 'SLUG', None) else module.NAME)) for module in registry.plugin_modules); registry.reload_plugins(full_reload=True, force_reload=True, collect=True); plugin_slugs = ('inventree-usd-irt-exchange-rate', 'inventree-stock-xlsx-adjustment'); assert all(registry.get_plugin(slug) for slug in plugin_slugs), 'Mandatory plugins failed to load'; from django.core.management import call_command; call_command('migrate', interactive=False, run_syncdb=True); from django.db.migrations.recorder import MigrationRecorder; assert MigrationRecorder.Migration.objects.filter(app='inventree_usd_irt_exchange_rate', name='0001_price_exchange_snapshot').exists(), 'USD/IRT snapshot migration failed'"
    )
    Invoke-Compose -ArgumentList @('run', '--rm', 'inventree-server', 'invoke', 'static')
    Invoke-Compose -ArgumentList @('run', '--rm', 'inventree-server', 'invoke', 'int.clean-settings')
    if ($TrainingData) {
        Initialize-TrainingCurrency
    }

    if (-not $SkipAdmin -and (Get-ExistingAdminCount) -eq 0) {
        Write-Step 'Create the first InvenTree administrator'
        Invoke-Compose -ArgumentList @('run', '--rm', 'inventree-server', 'invoke', 'superuser')
    }

    Write-Step 'Starting InvenTree'
    Invoke-Compose -ArgumentList @(
        'up', '-d', '--pull', 'never', '--no-build', '--wait', '--wait-timeout', '300',
        'inventree-db', 'inventree-cache', 'inventree-server', 'inventree-proxy'
    )
    Invoke-Compose -ArgumentList @('up', '-d', '--pull', 'never', '--no-build', 'inventree-worker')

    $workerHealthy = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        if (Test-ComposeCommand -ArgumentList @('exec', '-T', 'inventree-worker', 'invoke', 'worker-health', '--timeout=3')) {
            $workerHealthy = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $workerHealthy) {
        Throw-InstallerError 'InvenTree started, but its background worker is not healthy'
    }

    Wait-ForApplicationHealth
    $runningVersions = Invoke-Compose -ArgumentList @(
        'exec', '-T', 'inventree-server', 'python', '-c',
        $pluginVersionCommand
    ) -CaptureOutput
    if ((Get-LastOutputLine -Output $runningVersions) -ne $expectedPluginVersions) {
        Throw-InstallerError 'Running plugin version verification failed'
    }

    $activePlugins = Invoke-Compose -ArgumentList @(
        'exec', '-T', 'inventree-server', 'python', 'src/backend/InvenTree/manage.py', 'shell', '-c',
        "from plugin.registry import registry; print('|'.join('active' if registry.get_plugin(slug) else 'inactive' for slug in ('inventree-usd-irt-exchange-rate', 'inventree-stock-xlsx-adjustment')))"
    ) -CaptureOutput
    if ((Get-LastOutputLine -Output $activePlugins) -ne 'active|active') {
        Throw-InstallerError 'One or more required plugins are installed but not active'
    }
    if ($TrainingData) {
        Assert-TrainingData
    }

    $marker = @(
        "INSTALLER_FORMAT_VERSION=$($script:Versions.INSTALLER_FORMAT_VERSION)",
        "PLUGIN_VERSION=$($script:Versions.PLUGIN_VERSION)",
        "STOCK_PLUGIN_VERSION=$($script:Versions.STOCK_PLUGIN_VERSION)",
        "PLUGIN_COMMIT=$($script:Versions.PLUGIN_COMMIT)",
        "TRAINING_DATA=$($TrainingData.IsPresent.ToString().ToLowerInvariant())",
        "TRAINING_DATASET_COMMIT=$($script:Versions.TRAINING_DATASET_COMMIT)"
    ) -join "`n"
    Write-ProtectedFileTransactionally -Destination $markerPath -Content ($marker + "`n")

    Write-Step "InvenTree is ready at http://localhost:$($script:EffectiveHttpPort)"
    Write-Host "Data and automatic backups: $(Join-Path $InstallDirectory 'inventree-data')"
    Write-Host 'TGJU live updates are disabled by default. Configure the plugin in Admin Center to enable them.'
    if ($TrainingData) {
        Write-Host 'Training accounts: admin/inventree, allaccess/nolimits, reader/readonly, engineer/partsonly'
        Write-Host "Training USD/IRT rate: 1 USD = $($script:Versions.TRAINING_USD_IRT_RATE) IRT (sample only, not a live market quote)."
    }
}

function Initialize-Arguments {
    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle) -and
        -not [string]::IsNullOrWhiteSpace($BundleDirectory)) {
        Throw-InstallerError 'Use either -OfflineBundle or -BundleDirectory, not both'
    }
    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle) -and $NoOfflineCache) {
        Throw-InstallerError '-NoOfflineCache is not valid with -OfflineBundle'
    }
    if ($PrepareOnly -and $NoOfflineCache) {
        Throw-InstallerError '-PrepareOnly requires an offline bundle output and cannot be combined with -NoOfflineCache'
    }
    if ($PrepareOnly -and -not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        Throw-InstallerError '-PrepareOnly creates a new bundle and cannot be combined with -OfflineBundle'
    }
    if ($PrepareOnly -and $TrainingData) {
        Throw-InstallerError '-TrainingData deploys a training instance and cannot be combined with -PrepareOnly'
    }

    $script:InstallDirectory = Resolve-AbsolutePath -Path $InstallDirectory
    Assert-NoReparsePath -Path $script:InstallDirectory -Label 'Install directory'
    $markerPath = Join-Path $script:InstallDirectory '.installed'
    if ($TrainingData -and (Test-Path -LiteralPath $markerPath)) {
        Assert-RegularFile -Path $markerPath
        Throw-InstallerError '-TrainingData is only allowed during the first installation; existing data was not changed'
    }

    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        $script:OfflineBundle = Resolve-AbsolutePath -Path $OfflineBundle
        Assert-NoReparsePath -Path $script:OfflineBundle -Label 'Offline bundle'
        if (Test-PathWithin -Candidate $script:InstallDirectory -Parent $script:OfflineBundle) {
            Throw-InstallerError 'Install directory cannot equal or be inside the offline bundle'
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($BundleDirectory)) {
        $script:BundleDirectory = Resolve-AbsolutePath -Path $BundleDirectory
    }
    else {
        $script:BundleDirectory = Resolve-AbsolutePath -Path (Join-Path $InstallDirectory 'offline-bundle-windows-amd64')
    }
    Assert-NoReparsePath -Path $script:BundleDirectory -Label 'Bundle output'
    if ($script:BundleDirectory -eq [IO.Path]::GetPathRoot($script:BundleDirectory)) {
        Throw-InstallerError 'Bundle output cannot be a filesystem root'
    }
}

function Main {
    Assert-WindowsHost
    Initialize-Arguments

    if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
        Initialize-OfflineBundle
    }
    else {
        $script:Versions = Read-StrictKeyValueFile -Path (Join-Path $script:ScriptDirectory 'versions.env')
        Assert-VersionManifest
    }

    Ensure-Docker
    Assert-DockerPlatform

    $installLock = $null
    $exportLock = $null
    try {
        if (-not $PrepareOnly -or -not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
            $installLock = Enter-InstallLock
        }
        if ([string]::IsNullOrWhiteSpace($OfflineBundle)) {
            $exportLock = Enter-ExportLock
        }

        if (-not [string]::IsNullOrWhiteSpace($OfflineBundle)) {
            Load-OfflineImages
        }
        else {
            Acquire-ApplicationImages
            if ($TrainingData -and $NoOfflineCache) {
                Get-TrainingDatasetOnline | Out-Null
            }
            if (-not $NoOfflineCache) {
                Get-OnlineWslInstaller | Out-Null
                Export-OfflineBundle -LockHandle $exportLock
            }
        }

        if ($PrepareOnly) {
            Write-Step 'Preparation complete'
            if ([string]::IsNullOrWhiteSpace($OfflineBundle) -and -not $NoOfflineCache) {
                Write-Host "Complete offline bundle: $BundleDirectory"
                $imageArchive = Join-Path $BundleDirectory 'images.tar'
                $dockerInstaller = Join-Path $BundleDirectory (
                    "prerequisites\windows\DockerDesktop-$($script:Versions.DOCKER_DESKTOP_VERSION)-$($script:Versions.DOCKER_DESKTOP_BUILD)-x64.exe"
                )
                $wslInstaller = Join-Path $BundleDirectory (
                    "prerequisites\windows\wsl-$($script:Versions.WSL_VERSION)-x64.msi"
                )
                Write-Host "Container image archive: $imageArchive"
                Write-Host "Docker Desktop installer: $dockerInstaller"
                Write-Host "WSL installer: $wslInstaller"
                Write-Host "Manual image load: docker image load --input `"$imageArchive`""
            }
            return
        }

        Prepare-DeploymentFiles
        Deploy-Application
    }
    finally {
        if ($null -ne $exportLock) {
            Exit-ExportLock -Handle $exportLock
        }
        if ($null -ne $installLock) {
            Exit-InstallLock -Handle $installLock
        }
    }
}

Main
