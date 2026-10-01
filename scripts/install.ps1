<#
.SYNOPSIS
Install metacodes on Windows from a release archive (or an unpacked release
unit): the TUI, TinyKG (CLI + daemon) and both Lean kernels, as one isolated
install with its own state root.

.DESCRIPTION
This script only unpacks; the install itself is `bin\metacodes.exe install`
inside the unit (src/app/install.zig), the same code on every platform
(doc/INSTALL_DESIGN.md §4). By default the install's bin directory is added
to the user PATH so `metacodes` runs in any new terminal; -NoPath skips that.
An archive with an `<archive>.sha256` sidecar beside it is checked first.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 metacodes-<version>-x86_64-windows-gnu.zip

.EXAMPLE
powershell -File scripts\install.ps1 -Prefix C:\tools\mc-work -Sdk agentcore-<version>.zip metacodes-<version>.zip
#>
[CmdletBinding()]
param(
    # The release archive (.zip) or an unpacked release unit directory.
    [Parameter(Mandatory = $true, Position = 0)][string]$Unit,
    # Install here (default: %LOCALAPPDATA%\Programs\metacodes).
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\metacodes'),
    # Keep this install's state there (default: <Prefix>\state).
    [string]$StateDir,
    # Also install the AgentCore SDK (archive or directory) under <Prefix>\sdk\agentcore.
    [string]$Sdk,
    # Write a `<LinkName>.cmd` launcher into this directory as well.
    [string]$LinkDir,
    [string]$LinkName = 'metacodes',
    # Do not add <Prefix>\bin to the user PATH.
    [switch]$NoPath,
    # Replace a different version or foreign files at -Prefix.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-UnitRoot([string]$Directory) {
    if (Test-Path -LiteralPath (Join-Path $Directory 'manifest.json') -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Directory).Path
    }
    foreach ($child in Get-ChildItem -LiteralPath $Directory -Directory) {
        if (Test-Path -LiteralPath (Join-Path $child.FullName 'manifest.json') -PathType Leaf) {
            return $child.FullName
        }
    }
    throw "install.ps1: $Directory holds no release manifest.json"
}

function Expand-Unit([string]$Path, [string]$Name, [string]$Work) {
    if (Test-Path -LiteralPath $Path -PathType Container) { return Get-UnitRoot $Path }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "install.ps1: $Path does not exist" }
    $sidecar = "$Path.sha256"
    if (Test-Path -LiteralPath $sidecar -PathType Leaf) {
        $expected = ((Get-Content -LiteralPath $sidecar -TotalCount 1) -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { throw "install.ps1: $Path SHA-256 $actual does not match $sidecar ($expected)" }
    }
    $destination = Join-Path $Work $Name
    Expand-Archive -LiteralPath $Path -DestinationPath $destination -Force
    return Get-UnitRoot $destination
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("metacodes-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $root = Expand-Unit $Unit 'cli' $work
    $exe = Join-Path $root 'bin\metacodes.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "install.ps1: $exe is missing; is this a metacodes release unit?" }

    $installArgs = @('install', '--prefix', $Prefix)
    if ($StateDir) { $installArgs += @('--state-dir', $StateDir) }
    if ($Sdk) { $installArgs += @('--sdk', (Expand-Unit $Sdk 'sdk' $work)) }
    if ($LinkDir) { $installArgs += @('--link', $LinkDir, '--link-name', $LinkName) }
    if ($Force) { $installArgs += '--force' }

    & $exe @installArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    if (-not $NoPath) {
        $bin = Join-Path ([IO.Path]::GetFullPath($Prefix)) 'bin'
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        $entries = @()
        if ($userPath) { $entries = $userPath -split ';' | Where-Object { $_ } }
        if ($entries -notcontains $bin) {
            [Environment]::SetEnvironmentVariable('Path', (($entries + $bin) -join ';'), 'User')
            Write-Host "added $bin to the user PATH; open a new terminal to run metacodes"
        }
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
