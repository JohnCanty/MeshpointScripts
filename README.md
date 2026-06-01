# MeshpointScripts

Small Bash utilities for updating the radio firmware and related host-side components used by a Meshpoint setup.

Clone the repository into `~/MeshpointScripts` so the examples below match the expected checkout location:

```bash
git clone https://github.com/JohnCanty/MeshpointScripts.git ~/MeshpointScripts
cd ~/MeshpointScripts
```

Unless noted otherwise, the command examples below assume your current working directory is `~/MeshpointScripts`.

This repository currently contains four primary updater scripts plus one compatibility entry point:

| Script | Purpose |
| --- | --- |
| [update.sh](./update.sh) | Refresh the managed scripts and shared helpers in this repo from the public `main` branch with a single command. |
| [update_meshcore.sh](./update_meshcore.sh) | Query or flash the latest MeshCore Companion Firmware for a Heltec V3 radio, apply a radio preset, and record the flashed release in a local state file. |
| [update_meshtastic.sh](./update_meshtastic.sh) | Query or flash the latest Meshtastic ESP32-S3 release for a Heltec V3, then apply the selected region and owner while recording the flashed release in a local state file. |
| [update_reticulum.sh](./update_reticulum.sh) | Query or update an attached RNode using the Reticulum virtual environment and `rnodeconf --autoinstall`. |

Shared helper files:

- [github_release_common.sh](./github_release_common.sh): anonymous public GitHub tag and release-asset discovery used by the MeshCore and Meshtastic updaters.
- [tui_common.sh](./tui_common.sh): shared interactive prompt helpers used by all updater scripts.

Compatibility entry point:

- [update_meshpoint_scripts.sh](./update_meshpoint_scripts.sh): underlying implementation used by [update.sh](./update.sh) and kept as a backward-compatible entry point.

## Scope

These scripts are written for Linux hosts. They assume:

- `bash` is available.
- `git` is available.
- Serial devices appear as paths such as `/dev/ttyUSB0`.
- Tools like `systemctl`, `lsof`, `logger`, `curl`, `python3`, and `sudo` exist where needed.
- The relevant Python virtual environments already exist on the host.

They are operational scripts, not a general-purpose flashing framework. Defaults such as service names, log paths, owners, regions, and virtual environment locations are still defined in each file, but the scripts now share a more uniform interface.

Common operational flags:

- `--port PATH`: use an explicit serial device instead of the positional argument.
- `--show-device-info`: interrogate the attached device without flashing it.
- `--tui`: launch an interactive menu flow that gathers the remaining required settings.
- `--log-file PATH`: override the default log destination.
- `--force`: bypass the normal version or state-file skip logic.
- `--service NAME`: override the systemd service that should be stopped and restarted when the port is normally in use.

The `--tui` mode is intended for running a script without any additional arguments. Each script presents menus for the action, serial port, service name, logging, and any script-specific settings before continuing with the normal non-interactive logic.

The MeshCore and Meshtastic updaters now resolve public release tags anonymously with `git ls-remote` and download firmware assets from public GitHub release pages. No `GH_TOKEN` is required.

## Virtual Environment Setup

This repository does not include a shared `requirements.txt` because each updater expects a different virtual environment and different Python packages.

Before creating the venvs, make sure the host already has the non-Python tools used by these scripts, including `curl`, `git`, `lsof`, `logger`, `python3`, `sudo`, and, where applicable, `systemctl` and `unzip`.

The scripts assume these exact virtual environment paths:

- `update_meshcore.sh`: `~/meshcore-venv`
- `update_meshtastic.sh`: `~/meshtastic-venv`
- `update_reticulum.sh`: `/var/lib/reticulum/venv`

If you choose different paths, edit the `VENV` variable near the top of the corresponding script.

### MeshCore Requirements

`update_meshcore.sh` expects both `esptool` and `meshcli` in `~/meshcore-venv/bin/`.

```bash
python3 -m venv ~/meshcore-venv
~/meshcore-venv/bin/pip install --upgrade pip wheel esptool meshcore-cli
```

### Meshtastic Requirements

`update_meshtastic.sh` expects both `esptool` and the Meshtastic CLI in `~/meshtastic-venv`.

```bash
python3 -m venv ~/meshtastic-venv
~/meshtastic-venv/bin/pip install --upgrade pip wheel esptool meshtastic
```

### Reticulum Requirements

`update_reticulum.sh` runs `pip` and `rnodeconf` as the `reticulum` user, so the venv should be owned by that account.

```bash
sudo install -d -o reticulum -g reticulum /var/lib/reticulum
sudo python3 -m venv /var/lib/reticulum/venv
sudo chown -R reticulum:reticulum /var/lib/reticulum/venv
sudo -u reticulum /var/lib/reticulum/venv/bin/pip install --upgrade pip wheel rns
```

This should provide both the `rns` package and the `rnodeconf` executable used by the script.

### Quick Verification

After creating the environments, verify the expected executables exist:

```bash
~/meshcore-venv/bin/esptool version
~/meshcore-venv/bin/meshcli --help
~/meshtastic-venv/bin/esptool version
~/meshtastic-venv/bin/meshtastic --help
sudo -u reticulum /var/lib/reticulum/venv/bin/rnodeconf --help
```

## Interrogating Devices

All three updaters now expose a query-only mode that avoids flashing and just prints the current device information:

```bash
./update_meshcore.sh /dev/ttyUSB0 --show-device-info
./update_meshtastic.sh /dev/ttyUSB0 --show-device-info
sudo ./update_reticulum.sh /dev/ttyUSB0 --show-device-info
```

All three updaters also expose a TUI mode that can collect the required inputs interactively:

```bash
./update_meshcore.sh --tui
./update_meshtastic.sh --tui
sudo ./update_reticulum.sh --tui
```

If you want to query the MeshCore companion directly with the CLI, the current firmware version command is:

```bash
~/meshcore-venv/bin/meshcli -s /dev/ttyUSB0 ver
```

The MeshCore updater's `--show-device-info` path wraps `infos`, `ver`, and `get radio` so you can inspect all three together.

## Repository Layout

### [github_release_common.sh](./github_release_common.sh)

Shared Bash helper library for anonymous public GitHub release discovery.

What it is for:

- It is sourced by [update_meshcore.sh](./update_meshcore.sh) and [update_meshtastic.sh](./update_meshtastic.sh); it is not intended to be run directly as a standalone command.
- It centralizes the unauthenticated GitHub logic so the firmware scripts do not each have to parse tags and release pages separately.

Available functions:

- `github_public_repo_url REPO`: prints the public HTTPS git URL for a repository slug such as `meshtastic/firmware`.
- `github_latest_tag_matching REPO TAG_REGEX`: prints the newest matching tag by querying public tags with `git ls-remote`.
- `github_release_published_at REPO TAG`: prints the ISO 8601 release timestamp parsed from the public release page.
- `github_release_asset_info REPO TAG ASSET_REGEX [first|last]`: prints a tab-separated `asset_url` and `asset_name` for the matching asset on that release page.
- `github_latest_release_asset_info REPO TAG_REGEX ASSET_REGEX [first|last]`: prints a tab-separated `release_ref`, `published_at`, `tag_name`, `asset_url`, and `asset_name` tuple for the latest matching release.

Usage pattern:

```bash
source ./github_release_common.sh

latest_tag="$(github_latest_tag_matching "meshtastic/firmware" '^v')"
published_at="$(github_release_published_at "meshtastic/firmware" "$latest_tag")"

IFS=$'\t' read -r asset_url asset_name \
	< <(github_release_asset_info \
		"meshtastic/firmware" \
		"$latest_tag" \
		'^firmware-esp32s3-.*\.zip$' \
		last)

printf 'tag=%s\npublished_at=%s\nasset=%s\nurl=%s\n' \
	"$latest_tag" "$published_at" "$asset_name" "$asset_url"
```

Single-call example:

```bash
source ./github_release_common.sh

IFS=$'\t' read -r release_ref published_at tag_name asset_url asset_name \
	< <(github_latest_release_asset_info \
		"meshcore-dev/MeshCore" \
		'^companion-v' \
		'^Heltec_v3_companion_radio_usb-.*-merged\.bin$')
```

Notes:

- `release_ref` and `tag_name` are currently the same string because public page parsing gives the tag as the stable release identifier.
- The helper expects `git`, `curl`, and `python3` to be available on the host.

### [update_meshcore.sh](./update_meshcore.sh)

Updates MeshCore Companion Firmware for a Heltec V3 board.

What it does:

- Stops the service that normally owns the serial port, `meshpoint` by default.
- Uses `meshcli` to read the current node info, firmware version, and radio settings when requested.
- Verifies the attached device responds as an `esp32s3`.
- Resolves the newest public MeshCore companion tag with `git ls-remote` and fetches the matching release asset from GitHub.
- Skips flashing if the recorded state file already reflects an equal or newer published release, unless `--force` is used.
- Downloads, erases, flashes, applies the selected radio preset or custom radio tuple, verifies the device info after reboot, then writes release metadata to a local JSON state file.
- Attempts to restart the stopped service on exit.

Default paths and settings:

- Virtual environment: `~/meshcore-venv`
- Log file: `~/meshcore_update.log`
- State file: `~/.meshcore_companion_last_flash.json`
- Default transport: `usb`
- Default radio preset: `us915-legacy` (`910.525,250,11,5`)
- Default service: `meshpoint`

Common radio presets:

- `us915-legacy`: `910.525,250,11,5` (backward-compatible default)
- `usa-canada-recommended`: `910.525,62.5,7,5`
- `eu-uk-narrow`: `869.618,62.5,8,8`
- `australia-narrow`: `916.575,62.5,7,8`
- `new-zealand-narrow`: `917.375,62.5,7,5`
- `eu-433-narrow`: `433.650,62.5,8,8`

Run `./update_meshcore.sh --list-radio-presets` to print the full built-in preset table.

Usage:

```bash
./update_meshcore.sh /dev/ttyUSB0
./update_meshcore.sh --tui
./update_meshcore.sh /dev/ttyUSB0 --show-device-info
./update_meshcore.sh /dev/ttyUSB0 --radio-preset eu-uk-narrow
./update_meshcore.sh /dev/ttyUSB0 --radio-params 869.618,62.5,8,8
./update_meshcore.sh /dev/ttyUSB0 --transport ble --force
./update_meshcore.sh /dev/ttyUSB0 --service meshpoint --log-file /var/log/meshcore_update.log
./update_meshcore.sh --list-radio-presets
```

Notes:

- `esptool` and `meshcli` must exist in `~/meshcore-venv/bin/` unless you edit the script.
- `git` is required because the script resolves the newest companion tag anonymously before downloading the public release asset.
- `meshcli -s /dev/ttyUSB0 ver` is the direct CLI command to read the current MeshCore firmware version.
- `--tui` can walk you through action selection, transport, radio preset or tuple, service name, log file, and force mode.
- The script uses public GitHub release page timestamps to decide whether flashing is needed.

### [update_meshtastic.sh](./update_meshtastic.sh)

Downloads and flashes the latest Meshtastic firmware zip for ESP32-S3 Heltec V3 hardware.

What it does:

- Stops the service that normally owns the serial port, `meshpoint` by default.
- Uses the Meshtastic CLI `--info` path to interrogate the attached device when requested.
- Confirms required tools exist and the target port is not in use.
- Verifies the attached device responds via `esptool`.
- Resolves the newest public Meshtastic tag with `git ls-remote` and fetches the matching release asset from GitHub.
- Skips flashing if the recorded state file already reflects an equal or newer published release, unless `--force` is used.
- Downloads and extracts the newest `firmware-esp32s3-*.zip` asset.
- Selects the non-update `firmware-heltec-v3-*.bin` image.
- Erases and flashes the board.
- Applies the selected Meshtastic region and owner with the CLI.
- Re-reads device info after flashing and writes the flashed release metadata to a local JSON state file.
- Leaves the extracted artifacts in place on failure for inspection.

Default paths and settings:

- Working directory: `~/MeshtasticDL`
- Log file: `~/MeshtasticDL/flash-YYYYMMDDTHHMMSS.log`
- State file: `~/.meshtastic_last_flash.json`
- Virtual environment: `~/meshtastic-venv`
- `esptool`: `~/meshtastic-venv/bin/esptool`
- Meshtastic CLI: `~/meshtastic-venv/bin/meshtastic`
- Default region: `US`
- Default owner: `Meshpoint-Home`
- Default service: `meshpoint`

Usage:

```bash
./update_meshtastic.sh /dev/ttyUSB0
./update_meshtastic.sh --tui
./update_meshtastic.sh /dev/ttyUSB0 --show-device-info
./update_meshtastic.sh /dev/ttyUSB0 --region US --owner Meshpoint-Home
./update_meshtastic.sh /dev/ttyUSB0 --force
```

Notes:

- No `GH_TOKEN` is required; release discovery and downloads are anonymous.
- `git` is required because the script resolves the newest public tag before downloading the matching release asset.
- `meshtastic --port /dev/ttyUSB0 --info` is the direct CLI command the script uses to interrogate the current device.
- Region and owner are now configurable with `--region` and `--owner`.
- `--tui` can walk you through action selection, region, owner, service name, log file, and force mode.
- On failure, downloaded artifacts are intentionally left in place for inspection under the generated working directory.

### [update_reticulum.sh](./update_reticulum.sh)

Updates an attached RNode using the Reticulum virtual environment already present on the host.

What it does:

- Must be run as `root` or through `sudo`.
- Verifies the serial device exists, is not busy, and that the configured systemd service exists.
- Uses `rnodeconf --info` to read the current device information and firmware version.
- Uses `pip index versions rns` to determine the latest available `rns` package version.
- Skips the update if those versions match, unless `--force` is used.
- Stops the configured service before update if it is active.
- Upgrades `rns` inside the Reticulum virtual environment.
- Runs `rnodeconf --autoinstall` against the attached radio.
- Re-reads device info after update, restarts the service, and checks that it becomes active again.

Default paths and settings:

- Log file: `/var/log/rnode-update.log`
- Virtual environment: `/var/lib/reticulum/venv`
- Service name: `reticulum`

Usage:

```bash
sudo ./update_reticulum.sh /dev/ttyUSB0
sudo ./update_reticulum.sh --tui
sudo ./update_reticulum.sh /dev/ttyUSB0 --show-device-info
sudo ./update_reticulum.sh /dev/ttyUSB0 --force
```

Notes:

- The script runs `pip` and `rnodeconf` as the `reticulum` user.
- `sudo -u reticulum /var/lib/reticulum/venv/bin/rnodeconf --info /dev/ttyUSB0` is the direct CLI command the script uses to interrogate the current device.
- `--tui` can walk you through action selection, service name, log file, and force mode.
- If the update path fails, the `EXIT` trap attempts to restart the configured service.

### [update.sh](./update.sh)

Refreshes the managed repository files from the public `main` branch.

What it does:

- Resolves a public HTTPS URL for the current repository, based on `origin` by default.
- Fetches the requested branch into `FETCH_HEAD` without prompting for GitHub credentials.
- Limits updates to `README.md`, `github_release_common.sh`, `tui_common.sh`, `update.sh`, the three device updaters, and the compatibility entry point.
- Refuses to overwrite locally modified managed files unless `--force` is used.
- Updates only files that differ from the fetched branch and updates itself last.

Usage:

```bash
./update.sh --check
./update.sh
./update.sh --force
./update.sh --branch main --remote origin
```

Notes:

- `./update.sh` is the recommended operator entry point.
- `./update_meshpoint_scripts.sh` remains available and forwards to the same implementation.
- The script does not switch branches, create commits, or reset unrelated files.
- `--check` reports which managed files would change without writing them.
- `--force` is only needed when one of the managed files has local modifications you want to overwrite.

## Quick Start

1. From `~/MeshpointScripts`, refresh your local script copies from the public `main` branch when needed:

```bash
./update.sh --check
./update.sh
```

1. Review the script you plan to run and confirm its hard-coded defaults match your host.
1. Make sure no other process is using the target serial device.
1. Inspect the current attached device first when useful:

```bash
./update_meshcore.sh /dev/ttyUSB0 --show-device-info
./update_meshtastic.sh /dev/ttyUSB0 --show-device-info
sudo ./update_reticulum.sh /dev/ttyUSB0 --show-device-info
```

1. Or launch the interactive menu flow if you do not want to remember the flags:

```bash
./update_meshcore.sh --tui
./update_meshtastic.sh --tui
sudo ./update_reticulum.sh --tui
```

1. Run the built-in help for the script:

```bash
./update_meshcore.sh --help
./update_meshtastic.sh --help
./update_reticulum.sh --help
```

1. Run the updater against the correct serial port.

## Safety Notes

- These scripts perform destructive flash operations. Double-check the serial device path before running them.
- All three scripts may stop host services as part of the update or query flow when the serial port is owned by a systemd service.
- `update_reticulum.sh` writes to `/var/log` and requires elevated privileges.
- `update_meshcore.sh` and `update_meshtastic.sh` use local state files to decide whether the latest release has already been flashed.
- `update.sh` refuses to overwrite locally modified managed files unless you pass `--force`.

## Troubleshooting

If a script fails, start with the log file it reports:

- MeshCore: `~/meshcore_update.log`
- Meshtastic: `~/MeshtasticDL/flash-YYYYMMDDTHHMMSS.log`
- Reticulum: `/var/log/rnode-update.log`

Useful checks:

```bash
lsof /dev/ttyUSB0
systemctl status meshpoint --no-pager
systemctl status reticulum --no-pager
git status --short
./update.sh --check
./update_meshcore.sh /dev/ttyUSB0 --show-device-info
./update_meshtastic.sh /dev/ttyUSB0 --show-device-info
sudo ./update_reticulum.sh /dev/ttyUSB0 --show-device-info
```

If a script's defaults do not match your machine, prefer the available CLI flags first, then edit the variables near the top of that script only when a setting is not exposed as an option.
