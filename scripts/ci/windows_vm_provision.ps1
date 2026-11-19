# Prepares the Windows VM pool's golden image (doc/VM_POOLS.md, "AIPC"). Run it inside the golden VM, as its administrator, over PowerShell
# Direct from the pool host:
#
#   $admin = Get-Credential   # the account created while installing Windows
#   Invoke-Command -VMName metacodes-windows-golden -Credential $admin `
#     -FilePath scripts\ci\windows_vm_provision.ps1 `
#     -ArgumentList (Get-Content -Raw $HOME\.metacodes-runner\vm_password).Trim(), '<that account>'
#
# Afterwards the image has the `runner` account the pool host drives over
# PowerShell Direct (with the password the host keeps in vm_password), the
# tools the Windows gates expect from a hosted image, the pinned and checked
# Actions runner, and a start-up task that runs exactly one job: it waits for
# C:\pool\jit (handed over by the host), runs the runner with it and powers
# the VM off. The installing account is disabled and nothing in the image
# holds a credential. Tested by scripts/tests/test_vm_pool.py.
param(
  [Parameter(Mandatory = $true)][string]$RunnerPassword,
  [Parameter(Mandatory = $true)][string]$InstallAccount
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$RunnerVersion = '2.338.2'
$RunnerSha256 = 'a1f17aa987fc8158bc7521d284912267a0d01b7c2c4684b33c86783b5e8221cc'
$RunnerDir = 'C:\actions-runner'
$PoolDir = 'C:\pool'
if ($RunnerPassword.Length -lt 24) { throw 'the runner password must be at least 24 characters' }

# The account the host drives over PowerShell Direct and the runner runs as.
$secret = ConvertTo-SecureString $RunnerPassword -AsPlainText -Force
if (Get-LocalUser -Name runner -ErrorAction SilentlyContinue) {
  Set-LocalUser -Name runner -Password $secret -PasswordNeverExpires $true
} else {
  New-LocalUser -Name runner -Password $secret -PasswordNeverExpires -AccountNeverExpires | Out-Null
}
Add-LocalGroupMember -Group Administrators -Member runner -ErrorAction SilentlyContinue

# What the Windows gates expect from a hosted image (.github/workflows/ci.yml):
# Git with its bash on PATH, Python 3 with pip, ripgrep, and zstd for
# actions/cache. Chocolatey, as on GitHub's hosted images.
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  $env:Path += ';C:\ProgramData\chocolatey\bin'
}
choco install -y --no-progress git python312 ripgrep zstandard
if ($LASTEXITCODE -ne 0) { throw "choco install failed: $LASTEXITCODE" }
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
foreach ($dir in 'C:\Program Files\Git\bin', 'C:\Program Files\Git\cmd') {
  if ($machinePath -notlike "*$dir*") { $machinePath = "$machinePath;$dir" }
}
[Environment]::SetEnvironmentVariable('Path', $machinePath, 'Machine')
New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1 -PropertyType DWord -Force | Out-Null

# The Actions runner, pinned and checked.
$archive = Join-Path $env:TEMP 'actions-runner.zip'
Invoke-WebRequest -UseBasicParsing -OutFile $archive `
  -Uri "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
if ((Get-FileHash -Algorithm SHA256 $archive).Hash.ToLower() -ne $RunnerSha256) { throw 'the runner archive does not match its SHA-256' }
if (Test-Path $RunnerDir) { Remove-Item -Recurse -Force $RunnerDir }
Expand-Archive -Path $archive -DestinationPath $RunnerDir
Remove-Item -Force $archive

# The one-job task: wait for the configuration, run it, power off. Without a
# configuration the VM powers off too.
New-Item -ItemType Directory -Force -Path $PoolDir | Out-Null
@'
$ErrorActionPreference = 'Continue'
$jitPath = 'C:\pool\jit'
$deadline = (Get-Date).AddHours(2)
while (-not (Test-Path -LiteralPath $jitPath) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
if (Test-Path -LiteralPath $jitPath) {
  $jit = (Get-Content -Raw -LiteralPath $jitPath).Trim()
  Remove-Item -LiteralPath $jitPath -Force
  Set-Location 'C:\actions-runner'
  & .\run.cmd --jitconfig $jit *> 'C:\pool\runner.log'
}
Stop-Computer -Force
'@ | Set-Content -LiteralPath (Join-Path $PoolDir 'run-job.ps1') -Encoding ascii
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\pool\run-job.ps1'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'metacodes-pool-job' -Action $action -Trigger $trigger -Settings $settings `
  -User runner -Password $RunnerPassword -RunLevel Highest -Force | Out-Null

# A CI machine: no sleep, no updates, no indexing.
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
Set-Service -Name wuauserv -StartupType Disabled
Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
Set-Service -Name WSearch -StartupType Disabled -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionPath $RunnerDir -ErrorAction SilentlyContinue

# Nothing a job could take: the installing account goes, no keys or tokens stay.
if ($InstallAccount -ne 'runner') { Disable-LocalUser -Name $InstallAccount }
Remove-Item -Force -ErrorAction SilentlyContinue "$env:USERPROFILE\.ssh\id_*", "$env:USERPROFILE\.git-credentials"

# Full paths: this session's PATH predates the installs.
$versions = @(
  "runner $RunnerVersion",
  (& 'C:\Program Files\Git\cmd\git.exe' --version),
  (& 'C:\Python312\python.exe' --version 2>&1),
  (& 'C:\ProgramData\chocolatey\bin\rg.exe' --version | Select-Object -First 1)
)
$versions | Set-Content -LiteralPath (Join-Path $PoolDir 'image.txt') -Encoding ascii
Write-Output ("provisioned: " + ($versions -join '; '))
