param(
    [string]$Bindgen = "bindgen"
)

$ErrorActionPreference = "Stop"
$expectedVersion = "bindgen 0.72.1"
$actualVersion = (& $Bindgen --version).Trim()
if ($actualVersion -ne $expectedVersion) {
    throw "AgentCore Rust bindings require $expectedVersion, got $actualVersion"
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$header = Join-Path $repoRoot "sdk\metask\agentcore.h"
$checkedIn = Join-Path $repoRoot "sdk\rust\src\raw.rs"
$temporary = [System.IO.Path]::GetTempFileName()
try {
    & $Bindgen $header `
        --output $temporary `
        --allowlist-function '^metask_agentcore_.*' `
        --allowlist-type '^metask_agentcore_.*' `
        --allowlist-var '^METASK_AGENTCORE_.*' `
        --formatter rustfmt `
        -- -std=c11
    if ($LASTEXITCODE -ne 0) {
        throw "bindgen failed with exit code $LASTEXITCODE"
    }
    $generated = [System.IO.File]::ReadAllText($temporary).Replace("`r`n", "`n")
    $expected = [System.IO.File]::ReadAllText($checkedIn).Replace("`r`n", "`n")
    if (-not [string]::Equals($generated, $expected, [System.StringComparison]::Ordinal)) {
        throw "sdk/rust/src/raw.rs is stale; regenerate it with bindgen 0.72.1"
    }
} finally {
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
}
