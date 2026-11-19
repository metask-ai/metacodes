# The VM pools

> **Not in use yet.** Since 2026-11-19 the gates' self-hosted runners are the
> persistent `AppledeMac-Studio` and `AIPC`, carrying this document's labels,
> in the unsafe mode: only organization members' pull requests reach them
> ([CI_DESIGN.md](CI_DESIGN.md) §6). Nothing below protects them; `check`
> reports them as not retired. The pools replace them when a host passes
> `check` and `verify`.

CI's macOS and Windows gates run first on pools of single-use VMs, macOS on
the organization's Mac Studio and Windows on AIPC, and on GitHub-hosted
runners when a pool is off, full or not taking jobs
([CI_DESIGN.md](CI_DESIGN.md) §6). This document is the pools' design and
operating manual: what keeps a public repository's pull requests from
reaching anything they should not, how a pool host runs, and how to set one
up and keep it running.

| | macOS pool | Windows pool |
|---|---|---|
| Host | Mac Studio | AIPC |
| Backend | `tart` (Tart VMs, Softnet) | `hyperv` (Hyper-V VMs, port ACLs) |
| Golden image | `metacodes-macos-golden`, by [`scripts/ci/macos_vm_provision.sh`](../scripts/ci/macos_vm_provision.sh) | `metacodes-windows-golden.vhdx`, by [`scripts/ci/windows_vm_provision.ps1`](../scripts/ci/windows_vm_provision.ps1) |
| Slots | at most 2 (two macOS guests per Mac) | up to 8, as the machine allows |
| Label | `metacodes-macos-vm` | `metacodes-windows-vm` |

Both hosts run the same controller,
[`scripts/ci/vm_pool.py`](../scripts/ci/vm_pool.py), tested with both
provisioning scripts by `scripts/tests/test_vm_pool.py`.

The pools were decided on 2026-11-18 as the exceptions to the organization
policy that keeps public repositories off its self-hosted runners. On the
same day the organization's persistent runners on these machines,
`AppledeMac-Studio` and `AIPC`, were retired. The pools serve every pull
request, from forks too.

## 1. Security model

A self-hosted runner for a public repository is dangerous for three reasons,
not because the repository is public:

- **State.** A persistent machine lets one job tamper with the next (the
  runner, the caches, the toolchains) or take what it holds (credentials).
- **Position.** A machine on a network lets a job reach that network.
- **Sharing.** A machine that also serves private repositories exposes their
  code and credentials.

The pools remove all three, which leaves a job on a pool in the position of a
job on a GitHub-hosted runner. `ci.yml` decides where the gates run, but a
pull request runs its own copy of `ci.yml`, so nothing in a workflow file is
a boundary. The boundaries are these, and each one is required:

| | Requirement | Where it is held |
|---|---|---|
| M1 | One fresh VM per job, destroyed after it. Just-in-time runner registration: the runner takes one job and is gone. No runner on the host. | The controller: every turn creates a VM, runs one job and destroys the VM, whatever happens (tested). The Windows image's one task runs one job and powers off. |
| M2 | The GitHub App's private key stays on the host. A VM holds no token, no private key and no personal data. No host directory is shared into a VM. | The controller hands the single-use configuration over on standard input (SSH on macOS, PowerShell Direct on Windows), never in a command line; it refuses `--dir` and `--disk` for Tart and attaches nothing but the VM's own disk on Hyper-V. `verify` checks for credential files, secret variables and shared directories. |
| M3 | A VM reaches the internet, not private networks, the host or the other VMs. | macOS: Softnet; the controller refuses a configuration without `--net-softnet`. Windows: extended port ACLs on the virtual switch, outside the guest's reach, deny every private range (DHCP and DNS excepted); the controller refuses a configuration that leaves one open. `verify` checks what a VM reaches against what the host reaches. |
| M4 | A runner group of its own, limited to `metask-ai/metacodes`, is the only one that allows public repositories. The Default group never does. | Organization settings; `check` reports both groups. |
| M5 | Dedicated labels. Workflows never select a pool by `self-hosted`, `macOS` or `Windows`. | `scripts/tests/test_ci_pool_plan.py`: only the pool jobs use the labels, and no workflow uses `self-hosted`. |
| M6 | Fork pull request approval for all external contributors, at the repository and the organization. Two-factor authentication required for members. | Organization and repository settings. |
| M7 | Release workflows (`release.yml`, `release-tag.yml`, `rule-control.yml`) run on GitHub-hosted runners only. | The same test. |
| M8 | A hard time limit per job, and a log line per VM. | `job_limit_seconds`, `pool.log`. |

Never allow public repositories on the Default group. Never register a
persistent runner on a pool host, and never share a host cache into a VM.
`check` fails while `AppledeMac-Studio` or `AIPC` is still registered.

## 2. How a pool runs

A pool host is a dedicated machine on no private network, running one
service per slot under the dedicated account `ci-host`: launchd agents on the
Mac (Tart's macOS guests need the logged-in user's session, so `ci-host`
logs in automatically), Task Scheduler tasks at start-up on AIPC (Hyper-V
needs no session; `ci-host` is in Hyper-V Administrators and the task runs
with highest privileges).

One turn of a slot:

1. Remove the slot's leftovers: VMs a crash left behind, runners whose VM went
   away before they took a job.
2. Create `metacodes-s<slot>-<time>` from the golden image: `tart clone` (APFS
   copy on write), or a differencing VHDX over the read-only golden one plus
   a Generation 2 VM with its port ACLs.
3. Ask GitHub for a just-in-time runner configuration in the pool's runner
   group, with the pool's labels.
4. Start the VM and wait until it can take a job: an address and SSH, or
   PowerShell Direct and the runner in place.
5. Hand the configuration over: macOS starts `./run.sh --jitconfig` over SSH
   with it on standard input; Windows writes it to `C:\pool\jit` over
   PowerShell Direct, where the image's start-up task picks it up, runs the
   one job and powers the VM off. GitHub deletes the runner after its job.
6. Destroy the VM after the job, a failure or the job limit, and log the turn.

A slot boots its next VM as soon as the last is gone, so a free slot holds an
idle runner and a queued pool job starts within seconds.

## 3. Configuration

`~ci-host/.metacodes-runner/config.json`, read by every command. The Mac
Studio:

<!-- config example: tart -->
```json
{
  "backend": "tart",
  "owner": "metask-ai",
  "app_id": 1234567,
  "installation_id": 76543210,
  "private_key": "~/.metacodes-runner/app.pem",
  "runner_group_id": 7,
  "image": "metacodes-macos-golden",
  "vm_ssh_key": "~/.metacodes-runner/vm_key",
  "labels": ["self-hosted", "macOS", "ARM64", "metacodes-macos-vm"],
  "slots": 2,
  "tart_run_args": ["--no-graphics", "--net-softnet"],
  "job_limit_seconds": 5400
}
```

AIPC:

<!-- config example: hyperv -->
```json
{
  "backend": "hyperv",
  "owner": "metask-ai",
  "app_id": 1234567,
  "installation_id": 76543210,
  "private_key": "~/.metacodes-runner/app.pem",
  "runner_group_id": 7,
  "image": "metacodes-windows-golden",
  "vhd_dir": "D:/metacodes-pool",
  "vm_password_file": "~/.metacodes-runner/vm_password",
  "cpus": 8,
  "memory_mb": 16384,
  "labels": ["self-hosted", "Windows", "X64", "metacodes-windows-vm"],
  "slots": 2,
  "switch": "Default Switch",
  "job_limit_seconds": 5400
}
```

| Field | Meaning |
|---|---|
| `backend` | `tart` or `hyperv` |
| `owner`, `repository` | The organization; `repository` (default empty) registers repository-level runners instead, for an organization that cannot create runner groups |
| `app_id`, `installation_id`, `private_key` | The GitHub App both hosts use for just-in-time configurations (one App, one key file per host); on the Mac the key file must be mode 600 |
| `runner_group_id` | The pools' runner group (one group serves both pools) |
| `image` | The golden image: a Tart VM name, or the VHDX name in `vhd_dir` |
| `labels` | `self-hosted` plus the pool's dedicated label, which must equal the platform's `label` in `.github/runner-pools.json` |
| `slots` | At most 2 for `tart`, 8 for `hyperv`; must not exceed `slots` in `.github/runner-pools.json` |
| `job_limit_seconds` | The hard limit of one turn's job (default 5400) |
| `boot_timeout_seconds` | How long a VM may take to be ready (default 240 for `tart`, 600 for `hyperv`) |
| `state_dir`, `api_url` | Defaults: `~/.metacodes-runner`, `https://api.github.com` |
| `vm_ssh_key`, `vm_user`, `vm_runner_dir`, `tart_run_args` | `tart`: the host's private key for the VMs' `admin` user (its public half is in the image); the runner directory (`actions-runner`); arguments to `tart run`, which must include `--net-softnet` and must not share directories or disks |
| `vhd_dir`, `vm_password_file`, `cpus`, `memory_mb`, `switch`, `vm_user`, `vm_runner_dir`, `blocked_networks` | `hyperv`: where the golden and the per-VM disks live; the `runner` account's password (the host's only copy); each VM's processors and static memory; the virtual switch (default `Default Switch`, NAT with DHCP); the guest account (`runner`) and runner directory (`C:\actions-runner`); the networks each VM is denied, which must include every private range |

## 4. Commands

The same on both hosts (`python3` on the Mac, `python` on AIPC):

```sh
python3 scripts/ci/vm_pool.py check       # tools, key files, image, App access, runner groups, retired runners
python3 scripts/ci/vm_pool.py verify      # boot two VMs; what a job can reach and see
python3 scripts/ci/vm_pool.py once 1      # one turn of slot 1
python3 scripts/ci/vm_pool.py cleanup     # leftover pool VMs and offline pool runners
python3 scripts/ci/vm_pool.py service 1   # how to install slot 1: a LaunchAgent, or a Task Scheduler task
python3 scripts/ci/vm_pool.py slot 1      # what the service runs
```

`check` and `verify` print one `PASS`, `FAIL` or `NOTE` line per check and
exit non-zero on any `FAIL`. `verify` boots two VMs, so stop the slot
services first. A `NOTE` is an isolation probe it could not make meaningful:
the target is closed from the host too.

## 5. Setting up a host

Both hosts:

1. **Machine.** A dedicated machine on no private network, current OS, no
   sleep, and the non-administrator account `ci-host`.
2. **GitHub side** (an organization owner, once for both pools). The runner
   group, which allows only `metask-ai/metacodes` and public repositories
   and has no workflow restriction:
   ```sh
   gh api -X POST orgs/metask-ai/actions/runner-groups -f name=metacodes-public-ephemeral \
     -f visibility=selected -F "selected_repository_ids[]=$(gh api repos/metask-ai/metacodes --jq .id)" \
     -F allows_public_repositories=true
   ```
   and a GitHub App with only the organization permission "Self-hosted
   runners: Read and write" (for repository-level runners: repository
   "Administration: Read and write"), no webhook, installed on `metask-ai`.
   Each host keeps a copy of its private key at
   `~/.metacodes-runner/app.pem`.
3. **Retire the persistent runner** the machine held (`AppledeMac-Studio`,
   `AIPC`): unregister it, delete its directory and credentials and the
   self-hosted era's caches. `check` fails while either is registered.
4. **Configuration, check, verify, slots** (§3, §4): write `config.json`, run
   `check` and `verify` until every line passes, then install each slot with
   the output of `service N`.
5. **Switch it on.** A pull request sets the platform's `self_hosted` to
   `true` in `.github/runner-pools.json` and sizes `zig_build_jobs` to about
   twice the VM's processors, fewer if its memory is under 3 GB per job. Its
   own CI still runs where the switch it carries says.

### The Mac Studio (`tart`)

As `ci-host`, who logs in automatically (FileVault, if on, must resume after
a restart):

```sh
brew install cirruslabs/cli/tart cirruslabs/cli/softnet hudochenkov/sshpass/sshpass
mkdir -m 700 ~/.metacodes-runner && ssh-keygen -t ed25519 -N '' -f ~/.metacodes-runner/vm_key
# The golden image: a Cirrus Labs macOS 26 image with Xcode (what GitHub's
# hosted macos-latest runs), sized to half the host, provisioned once over its
# default password, which the script then replaces.
tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest metacodes-macos-golden
tart set metacodes-macos-golden --cpu <(cores - 2) / 2> --memory <(MB - 8192) / 2> --disk-size 150
tart run metacodes-macos-golden --no-graphics &
sshpass -p admin ssh -o StrictHostKeyChecking=no admin@"$(tart ip metacodes-macos-golden)" \
  "bash -s -- '$(cat ~/.metacodes-runner/vm_key.pub)'" < scripts/ci/macos_vm_provision.sh
tart stop metacodes-macos-golden
# Each slot.
python3 scripts/ci/vm_pool.py service 1 > ~/Library/LaunchAgents/ai.metask.metacodes-vm-pool.slot1.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.metask.metacodes-vm-pool.slot1.plist
```

Read Tart's current `LICENSE`: Cirrus Labs joined OpenAI in 2026 and
relicensed Tart.

### AIPC (`hyperv`)

Windows 11 Pro, Enterprise or Education, or Windows Server, with Hyper-V on
and virtualization enabled in the firmware. In an administrator PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All   # then restart
Add-LocalGroupMember -Group 'Hyper-V Administrators' -Member ci-host
winget install Python.Python.3.12 Git.Git                                   # python, and openssl with Git
```

Then, as `ci-host`:

1. **The golden VM.** A Generation 2 VM on `Default Switch` with Windows
   installed from an ISO (a licensed edition the organization owns, or an
   evaluation image while testing; GitHub's hosted runners are Windows Server
   2025). Keep the account created during setup for the next step only.
2. **Provision it.** Generate the `runner` password, keep it only in
   `vm_password` (readable by `ci-host` alone), and run the provisioning
   script inside the VM over PowerShell Direct:
   ```powershell
   $pw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
   Set-Content -NoNewline -Path $HOME\.metacodes-runner\vm_password -Value $pw
   icacls $HOME\.metacodes-runner\vm_password /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
   Invoke-Command -VMName metacodes-windows-golden -Credential (Get-Credential) `
     -FilePath scripts\ci\windows_vm_provision.ps1 -ArgumentList $pw, '<the setup account>'
   ```
3. **Freeze it.** Shut the VM down, copy its disk to
   `<vhd_dir>\metacodes-windows-golden.vhdx`, mark that file read-only and
   delete the golden VM: every pool VM is a differencing disk over it.
4. **Each slot.** Run the output of `python scripts\ci\vm_pool.py service 1`
   in an elevated PowerShell; it asks for `ci-host`'s password.

## 6. Operating a pool

- **Logs.** `~/.metacodes-runner/pool.log` holds one JSON line per turn (VM,
  runner exit, seconds, error). On the Mac the agents also write
  `slot-<n>.{out,err}.log`; on Windows the VM writes `C:\pool\runner.log`,
  which goes with the VM.
- **When a pool is down**, CI falls back on its own ([CI_DESIGN.md](CI_DESIGN.md)
  §6): new runs see a pool job that waited past the pickup timeout and go to
  hosted runners, and a run whose pool job no VM takes hands over to the
  hosted legs after the pickup timeout. For planned maintenance, switch the
  pool off in `.github/runner-pools.json` instead.
- **Stopping a slot.** Mac:
  `launchctl bootout gui/$(id -u)/ai.metask.metacodes-vm-pool.slot1`.
  Windows: `Stop-ScheduledTask metacodes-vm-pool-slot1`, then
  `python scripts\ci\vm_pool.py cleanup`.
- **Refreshing an image** (monthly, and when GitHub's hosted image moves to a
  new OS version): rebuild it under a new name, `verify` it, switch `image`,
  restart the slots, then delete the old image. Keep the runner version in
  both provisioning scripts current and equal (a test holds them equal): a
  stale runner updates itself on every job.
- **Rotating the App key.** Generate a new key in the App's settings, replace
  `app.pem` on both hosts, run `check`, then delete the old key.
