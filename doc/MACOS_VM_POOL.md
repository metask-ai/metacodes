# The macOS VM pool

CI's macOS gates run first on a pool of single-use macOS VMs on the
organization's Mac Studio, and on GitHub-hosted runners when the pool is off,
full or not taking jobs ([CI_DESIGN.md](CI_DESIGN.md) §6). This document is
the pool's design and operating manual: what keeps a public repository's pull
requests from reaching anything they should not, how the host runs, and how
to set it up and keep it running. The controller is
[`scripts/ci/macos_vm_pool.py`](../scripts/ci/macos_vm_pool.py), the golden
image's provisioning is
[`scripts/ci/macos_vm_provision.sh`](../scripts/ci/macos_vm_provision.sh),
and both are tested by `scripts/tests/test_macos_vm_pool.py`.

The pool was decided on 2026-11-18 as the one exception to the organization
policy that keeps public repositories off its self-hosted runners. On the
same day the organization's persistent macOS runner, `AppledeMac-Studio`,
was retired. The pool serves every pull request, from forks too.

## 1. Security model

A self-hosted runner for a public repository is dangerous for three reasons,
not because the repository is public:

- **State.** A persistent machine lets one job tamper with the next (the
  runner, the caches, the toolchains) or take what it holds (credentials).
- **Position.** A machine on a network lets a job reach that network.
- **Sharing.** A machine that also serves private repositories exposes their
  code and credentials.

The pool removes all three, which leaves a job on it in the position of a job
on a GitHub-hosted runner. `ci.yml` decides where the gates run, but a pull
request runs its own copy of `ci.yml`, so nothing in a workflow file is a
boundary. The boundaries are these, and each one is required:

| | Requirement | Where it is held |
|---|---|---|
| M1 | One fresh VM per job, destroyed after it. Just-in-time runner registration: the runner takes one job and is gone. No runner on the host. | The controller: every turn clones, runs one job and deletes the VM, whatever happens (tested) |
| M2 | The GitHub App's private key stays on the host. A VM holds no token, no private key (only the host's public key) and no personal data. No host directory is shared into a VM. | The controller passes the single-use configuration on SSH standard input, never in a command line, and refuses `--dir` in `tart_run_args`. `verify` checks for credential files, secret variables and shared directories. |
| M3 | A VM reaches the internet, not private networks, the host or the other VM. | Softnet: the controller refuses a configuration that does not run VMs with `--net-softnet`. `verify` checks what a VM reaches against what the host reaches. |
| M4 | A runner group of its own, limited to `metask-ai/metacodes`, is the only one that allows public repositories. The Default group never does. | Organization settings; `check` reports both groups. |
| M5 | A dedicated label, `metacodes-macos-vm`. Workflows never select the pool by `self-hosted` or `macOS`. | `scripts/tests/test_ci_macos_plan.py`: only the pool job uses the label, and no workflow uses `self-hosted`. |
| M6 | Fork pull request approval for all external contributors, at the repository and the organization. Two-factor authentication required for members. | Organization and repository settings. |
| M7 | Release workflows (`release.yml`, `release-tag.yml`, `rule-control.yml`) run on GitHub-hosted runners only. | The same test. |
| M8 | A hard time limit per job, and a log line per VM. | `job_limit_seconds`, `pool.log`. |

Never allow public repositories on the Default group: the organization's
other self-hosted runners (`AIPC`) are persistent. Never register a
persistent runner on the pool host, and never mount a host cache into a VM.

## 2. How it runs

The host is the Mac Studio, a dedicated machine on no private network. A
dedicated, non-administrator macOS user `ci-host` logs in automatically and
runs two launchd agents, one per slot. Virtualization.framework runs at most
two macOS guests per Mac, so `slots` is at most 2.

One turn of a slot:

1. Remove the slot's leftovers: VMs a crash left behind, runners whose VM went
   away before they took a job.
2. `tart clone` the golden image into `metacodes-s<slot>-<time>` (APFS copy on
   write: seconds).
3. Ask GitHub for a just-in-time runner configuration in the pool's runner
   group, with the pool's labels.
4. `tart run` the VM on Softnet and wait for its address and SSH.
5. Start `./run.sh --jitconfig` in the VM, the configuration on standard
   input. The runner waits for a job, runs it and exits; GitHub then deletes
   the runner.
6. Stop and delete the VM, after the job, a failure or the job limit, and log
   the turn.

Because the next VM boots as soon as the last is gone, a free slot holds an
idle runner and a queued pool job starts within seconds.

## 3. Configuration

`~ci-host/.metacodes-runner/config.json`, read by every command:

<!-- config example -->
```json
{
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
  "job_limit_seconds": 5400,
  "boot_timeout_seconds": 240
}
```

| Field | Meaning |
|---|---|
| `owner`, `repository` | The organization; `repository` (default empty) registers repository-level runners instead of organization-level ones, for an organization that cannot create runner groups |
| `app_id`, `installation_id`, `private_key` | The GitHub App the host uses for just-in-time configurations; the key file must be mode 600 |
| `runner_group_id` | The pool's runner group |
| `image` | The golden image's Tart name |
| `vm_ssh_key` | The host's private key for the VMs' `admin` user (`vm_user`); its public half is in the image |
| `labels` | `self-hosted` plus the pool's dedicated label, which must equal `label` in `.github/macos-runner.json` |
| `slots` | 1 or 2 |
| `tart_run_args` | Arguments to `tart run`: must include `--net-softnet`, must not share directories or disks |
| `job_limit_seconds` | The hard limit of one turn's job (default 5400) |
| `boot_timeout_seconds` | How long a VM may take to get an address and SSH (default 240) |
| `vm_runner_dir`, `state_dir`, `api_url` | Defaults: `actions-runner`, `~/.metacodes-runner`, `https://api.github.com` |

## 4. Commands

```sh
python3 scripts/ci/macos_vm_pool.py check            # tools, key modes, image, App access, runner groups
python3 scripts/ci/macos_vm_pool.py verify           # boot two VMs; what a job can reach and see
python3 scripts/ci/macos_vm_pool.py once 1           # one turn of slot 1
python3 scripts/ci/macos_vm_pool.py cleanup          # leftover pool VMs and offline pool runners
python3 scripts/ci/macos_vm_pool.py launchd-plist 1  # the LaunchAgent for slot 1
python3 scripts/ci/macos_vm_pool.py slot 1           # what launchd runs
```

`check` and `verify` print one `PASS`, `FAIL` or `NOTE` line per check and
exit non-zero on any `FAIL`. `verify` boots both slots' VMs, so stop the slot
agents first. A `NOTE` is an isolation probe it could not make meaningful:
the target is closed from the host too.

## 5. Setting up the host

1. **Machine.** The latest stable macOS; no sleep; the `ci-host` user (not an
   administrator) logging in automatically; FileVault, if on, able to resume
   after a restart. Install Homebrew, then
   `brew install cirruslabs/cli/tart cirruslabs/cli/softnet`. Read Tart's
   current `LICENSE`: Cirrus Labs joined OpenAI in 2026 and relicensed Tart.
2. **Keys.** As `ci-host`: `mkdir -m 700 ~/.metacodes-runner`, then
   `ssh-keygen -t ed25519 -N '' -f ~/.metacodes-runner/vm_key`.
3. **Runner group** (an organization owner). The group allows only
   `metask-ai/metacodes` and public repositories, and no workflow
   restriction:
   ```sh
   gh api -X POST orgs/metask-ai/actions/runner-groups -f name=metacodes-public-ephemeral \
     -f visibility=selected -F "selected_repository_ids[]=$(gh api repos/metask-ai/metacodes --jq .id)" \
     -F allows_public_repositories=true
   ```
4. **GitHub App** (an organization owner). Organization permission
   "Self-hosted runners: Read and write" only (for repository-level runners:
   repository "Administration: Read and write"), no webhook, installed on
   `metask-ai`. Save its private key as `~/.metacodes-runner/app.pem`, mode
   600.
5. **Golden image.** Clone a Cirrus Labs macOS 26 image with Xcode (macOS 26
   is what GitHub's hosted `macos-latest` runs), size it, boot it and
   provision it once over its default password, which the script then
   replaces:
   ```sh
   tart clone ghcr.io/cirruslabs/macos-tahoe-xcode:latest metacodes-macos-golden
   tart set metacodes-macos-golden --cpu <(cores - 2) / 2> --memory <(MB - 8192) / 2> --disk-size 150
   tart run metacodes-macos-golden --no-graphics &
   brew install hudochenkov/sshpass/sshpass
   sshpass -p admin ssh -o StrictHostKeyChecking=no admin@"$(tart ip metacodes-macos-golden)" \
     "bash -s -- '$(cat ~/.metacodes-runner/vm_key.pub)'" < scripts/ci/macos_vm_provision.sh
   tart stop metacodes-macos-golden
   ```
   Then set `zig_build_jobs` in `.github/macos-runner.json` to about twice the
   VM's cores, fewer if its memory is under 3 GB per job.
6. **Configuration, check, verify.** Write `config.json` (§3), then run
   `check` and `verify` until every line passes.
7. **Slots.** For each slot:
   ```sh
   python3 scripts/ci/macos_vm_pool.py launchd-plist 1 > ~/Library/LaunchAgents/ai.metask.metacodes-vm-pool.slot1.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.metask.metacodes-vm-pool.slot1.plist
   ```
   The organization's runner list shows an idle `metacodes-s1-…` runner.
8. **Retire the persistent runner.** Unregister `AppledeMac-Studio` and
   delete its directory, credentials and the self-hosted era's caches
   (`~/.cache/metacodes-zig`); `check` fails while it is registered.
9. **Switch it on.** A pull request sets `"self_hosted": true` in
   `.github/macos-runner.json`; its own CI still runs where the switch it
   carries says.

## 6. Operating it

- **Logs.** `~/.metacodes-runner/pool.log` holds one JSON line per turn (VM,
  runner exit, seconds, error); `slot-<n>.{out,err}.log` are the agents'.
- **When the pool is down**, CI falls back on its own ([CI_DESIGN.md](CI_DESIGN.md)
  §6): new runs see a pool job that waited past the pickup timeout and go to
  hosted runners, and a run whose pool job no VM takes hands over to the
  hosted legs after the pickup timeout. For planned maintenance, switch the
  pool off in `.github/macos-runner.json` instead.
- **Stopping a slot.**
  `launchctl bootout gui/$(id -u)/ai.metask.metacodes-vm-pool.slot1`; the
  controller destroys its current VM on the way out.
- **Refreshing the image** (monthly, and when GitHub's hosted image moves to
  a new macOS): rerun step 5 into a new name, `verify` it, switch `image`,
  restart the slots, then delete the old image. Keep `RUNNER_VERSION` in the
  provisioning script current: a stale runner updates itself on every job.
- **Rotating the App key.** Generate a new key in the App's settings, replace
  `app.pem`, run `check`, then delete the old key.
