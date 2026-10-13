<#
.SYNOPSIS
Install metacodes on Windows from a release archive (or an unpacked release
unit): the TUI, TinyKG (CLI + daemon) and both Lean kernels, as one isolated
install with its own state root.

.DESCRIPTION
This script only unpacks (and refuses a downgrade for a release up to 0.5.0,
whose own install does not); the install itself is `bin\metacodes.exe install`
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
    # Let a rerun replace a newer install with this older version.
    [switch]$AllowDowngrade,
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

# BEGIN version order
# Whether version $Candidate precedes $Installed in semantic-version order, as
# the installer itself orders them (src/app/install.zig isOlder over
# std.SemanticVersion): pre-releases before their release, build metadata
# ignored, and a version that does not parse is never older. install.sh
# version_older mirrors it; scripts/tests/test_install_scripts.py checks both
# against one table. Ordinal comparisons throughout: -lt and -match are
# culture-aware and case-insensitive.
function Test-OlderVersion([string]$Candidate, [string]$Installed) {
    # A numeric identifier: no leading zero, and it fits in 64 bits.
    function Test-Number([string]$Text) {
        if ($Text -cnotmatch '^(0|[1-9][0-9]*)$') { return $false }
        return ($Text.Length -lt 20 -or ($Text.Length -eq 20 -and [string]::CompareOrdinal($Text, '18446744073709551615') -le 0))
    }
    # Without leading zeros, numbers order by length, then digit by digit.
    function Compare-Number([string]$X, [string]$Y) {
        if ($X.Length -ne $Y.Length) { if ($X.Length -lt $Y.Length) { return -1 } else { return 1 } }
        return [Math]::Sign([string]::CompareOrdinal($X, $Y))
    }
    # Dot-separated identifiers of [0-9A-Za-z-], none empty.
    function Test-Identifiers([string]$Text) {
        foreach ($id in ($Text -split '\.')) { if ($id -cnotmatch '^[0-9A-Za-z-]+$') { return $false } }
        return $true
    }
    # @{ Core = three numbers; Pre = the pre-release or $null }, or $null.
    function Split-Version([string]$Text) {
        $cut = $Text.IndexOfAny([char[]]'-+')
        $core = $Text
        $pre = $null
        if ($cut -ge 0) {
            $core = $Text.Substring(0, $cut)
            $rest = $Text.Substring($cut + 1)
            $build = $rest
            if ($Text[$cut] -eq [char]'-') {
                $plus = $rest.IndexOf([char]'+')
                $build = $null
                $pre = $rest
                if ($plus -ge 0) { $pre = $rest.Substring(0, $plus); $build = $rest.Substring($plus + 1) }
                if (-not (Test-Identifiers $pre)) { return $null }
                foreach ($id in ($pre -split '\.')) {
                    if ($id -cmatch '^[0-9]+$' -and -not (Test-Number $id)) { return $null }
                }
            }
            if ($null -ne $build -and -not (Test-Identifiers $build)) { return $null }
        }
        $parts = @($core -split '\.')
        if ($parts.Count -ne 3) { return $null }
        foreach ($part in $parts) { if (-not (Test-Number $part)) { return $null } }
        return @{ Core = $parts; Pre = $pre }
    }

    $a = Split-Version $Candidate
    $b = Split-Version $Installed
    if ($null -eq $a -or $null -eq $b) { return $false }
    for ($i = 0; $i -lt 3; $i++) {
        $d = Compare-Number $a.Core[$i] $b.Core[$i]
        if ($d -ne 0) { return ($d -lt 0) }
    }
    if ($null -ne $a.Pre -and $null -eq $b.Pre) { return $true }
    if ($null -eq $a.Pre) { return $false }
    $pa = @($a.Pre -split '\.')
    $pb = @($b.Pre -split '\.')
    for ($i = 0; $i -lt [Math]::Min($pa.Count, $pb.Count); $i++) {
        $xn = $pa[$i] -cmatch '^[0-9]+$'
        $yn = $pb[$i] -cmatch '^[0-9]+$'
        # Numeric identifiers come before alphanumeric ones.
        if ($xn -ne $yn) { return $xn }
        if ($xn) { $d = Compare-Number $pa[$i] $pb[$i] } else { $d = [Math]::Sign([string]::CompareOrdinal($pa[$i], $pb[$i])) }
        if ($d -ne 0) { return ($d -lt 0) }
    }
    # A shorter list of otherwise equal identifiers comes first.
    return ($pa.Count -lt $pb.Count)
}
# END version order

$work = Join-Path ([IO.Path]::GetTempPath()) ("metacodes-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $root = Expand-Unit $Unit 'cli' $work
    $exe = Join-Path $root 'bin\metacodes.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "install.ps1: $exe is missing; is this a metacodes release unit?" }

    # A unit refuses to replace a newer install with an older version, but only
    # units released after 0.5.0 carry that check (their `install --help` names
    # --allow-downgrade). For an earlier unit this script makes the same check;
    # a unit that carries it decides for itself. Windows PowerShell turns a
    # native command's redirected stderr into errors, hence 'Continue'.
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $help = & $exe install --help 2>&1 | Out-String } finally { $ErrorActionPreference = $savedPreference }
    $unitGuards = $help -match '--allow-downgrade'
    $record = Join-Path $Prefix 'etc\metacodes\install.json'
    if (-not $unitGuards -and (Test-Path -LiteralPath $record -PathType Leaf)) {
        $unitVersion = $null
        $installedVersion = $null
        try { $unitVersion = (Get-Content -Raw -LiteralPath (Join-Path $root 'manifest.json') | ConvertFrom-Json).release.version } catch { }
        try { $installedVersion = (Get-Content -Raw -LiteralPath $record | ConvertFrom-Json).version } catch { }
        if ($unitVersion -and $installedVersion -and (Test-OlderVersion $unitVersion $installedVersion)) {
            if (-not $AllowDowngrade -and -not $Force) {
                throw "install.ps1: $Prefix holds metacodes $installedVersion, newer than $unitVersion; pass -AllowDowngrade to replace it with this older one, or choose another -Prefix"
            }
            Write-Host "install.ps1: replacing metacodes $installedVersion with the older $unitVersion"
        }
    }

    # --upgrade: rerunning replaces this product's other version (never with an
    # older one unless -AllowDowngrade), never foreign files.
    $installArgs = @('install', '--prefix', $Prefix, '--upgrade')
    if ($StateDir) { $installArgs += @('--state-dir', $StateDir) }
    if ($Sdk) { $installArgs += @('--sdk', (Expand-Unit $Sdk 'sdk' $work)) }
    if ($LinkDir) { $installArgs += @('--link', $LinkDir, '--link-name', $LinkName) }
    if ($Force) { $installArgs += '--force' }
    # Only a unit that knows the option gets it; an earlier one rejects it as
    # unknown (and was already checked above).
    if ($AllowDowngrade -and $unitGuards) { $installArgs += '--allow-downgrade' }

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
