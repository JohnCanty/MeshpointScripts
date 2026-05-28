# MeshpointScripts

Small Bash utilities for updating the radio firmware and related host-side components used by a Meshpoint setup.

This repository currently contains three scripts:

| Script | Purpose |
| --- | --- |
| [update_meshcore.sh](./update_meshcore.sh) | Flash the latest MeshCore Companion Firmware for a Heltec V3 radio and record the flashed release in a local state file. |
| [update_meshtastic.sh](./update_meshtastic.sh) | Download the latest Meshtastic ESP32-S3 release zip, flash the Heltec V3 image, then apply a default region and owner. |
| [update_reticulum.sh](./update_reticulum.sh) | Upgrade `rns` in the Reticulum virtual environment and run `rnodeconf --autoinstall` against an attached RNode. |

## Scope

These scripts are written for Linux hosts. They assume:

- `bash` is available.
- Serial devices appear as paths such as `/dev/ttyUSB0`.
- Tools like `systemctl`, `lsof`, `logger`, `curl`, `python3`, and `sudo` exist where needed.
- The relevant Python virtual environments already exist on the host.

They are operational scripts, not a general-purpose flashing framework. Defaults such as service names, log paths, owners, regions, and virtual environment locations are hard-coded in each file.

## Virtual Environment Setup

This repository does not include a shared `requirements.txt` because each updater expects a different virtual environment and different Python packages.

Before creating the venvs, make sure the host already has the non-Python tools used by these scripts, including `curl`, `lsof`, `logger`, `python3`, `sudo`, and, where applicable, `systemctl` and `unzip`.

The scripts assume these exact virtual environment paths:

- `update_meshcore.sh`: `~/meshcore-venv`
- `update_meshtastic.sh`: `~/meshtastic-venv`
- `update_reticulum.sh`: `/var/lib/reticulum/venv`

If you choose different paths, edit the `VENV` variable near the top of the corresponding script.

### MeshCore Requirements

`update_meshcore.sh` expects both `esptool` and `meshcli` in `~/meshcore-venv/bin/`.

```bash
python3 -m venv ~/meshcore-venv
~/meshcore-venv/bin/pip install --upgrade pip wheel esptool
# Install the MeshCore CLI package that provides `meshcli` into the same venv.
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

## Repository Layout

### [update_meshcore.sh](./update_meshcore.sh)

Updates MeshCore Companion Firmware for a Heltec V3 board.

What it does:

- Stops the service that normally owns the serial port, `meshpoint` by default.
- Verifies the attached device responds as an `esp32s3`.
- Queries GitHub for the newest MeshCore Companion Firmware release matching the requested transport.
- Skips flashing if the recorded state file already reflects an equal or newer published release, unless `--force` is used.
- Downloads, erases, flashes, applies the US 915 MHz radio defaults, verifies them after reboot, then writes release metadata to a local JSON state file.
- Attempts to restart the stopped service on exit.

Default paths and settings:

- Virtual environment: `~/meshcore-venv`
- Log file: `~/meshcore_update.log`
- State file: `~/.meshcore_companion_last_flash.json`
- Default transport: `usb`
- Default service: `meshpoint`

Usage:

```bash
./update_meshcore.sh /dev/ttyUSB0
./update_meshcore.sh /dev/ttyUSB0 --transport ble --force
./update_meshcore.sh /dev/ttyUSB0 --service meshpoint --log-file /var/log/meshcore_update.log
```

Notes:

- `esptool` and `meshcli` must exist in `~/meshcore-venv/bin/` unless you edit the script.
- The script uses GitHub release metadata timestamps to decide whether flashing is needed.

### [update_meshtastic.sh](./update_meshtastic.sh)

Downloads and flashes the latest Meshtastic firmware zip for ESP32-S3 Heltec V3 hardware.

What it does:

- Confirms required tools exist and the target port is not in use.
- Verifies the attached device responds via `esptool`.
- Pulls the latest Meshtastic firmware release from GitHub.
- Downloads and extracts the newest `firmware-esp32s3-*.zip` asset.
- Selects the non-update `firmware-heltec-v3-*.bin` image.
- Erases and flashes the board.
- Applies two post-flash settings with the Meshtastic CLI:
  - region: `US`
  - owner: `Meshpoint-Home`
- Removes the downloaded zip and extracted directory on success.

Default paths and settings:

- Working directory: `~/MeshtasticDL`
- Extracted firmware directory: `~/MeshtasticDL/firmware-esp32s3-latest`
- Virtual environment: `~/meshtastic-venv`
- `esptool`: `~/meshtastic-venv/bin/esptool`
- Meshtastic CLI: `~/meshtastic-venv/bin/meshtastic`

Usage:

```bash
./update_meshtastic.sh /dev/ttyUSB0
GH_TOKEN=your_token_here ./update_meshtastic.sh /dev/ttyUSB0
```

Notes:

- `GH_TOKEN` is optional but helps avoid GitHub API rate limits.
- If the Meshtastic CLI is missing, the script installs it into the configured virtual environment.
- Region and owner are fixed in the script. Edit the file if you need different defaults.
- On failure, downloaded artifacts are intentionally left in place for inspection.

### [update_reticulum.sh](./update_reticulum.sh)

Updates an attached RNode using the Reticulum virtual environment already present on the host.

What it does:

- Must be run as `root` or through `sudo`.
- Verifies the serial device exists, is not busy, and that the `reticulum` systemd service exists.
- Uses `rnodeconf --info` to read the device firmware version.
- Uses `pip index versions rns` to determine the latest available `rns` package version.
- Skips the update if those versions match.
- Stops the `reticulum` service.
- Upgrades `rns` inside the Reticulum virtual environment.
- Runs `rnodeconf --autoinstall` against the attached radio.
- Restarts the service and checks that it becomes active again.

Default paths and settings:

- Log file: `/var/log/rnode-update.log`
- Virtual environment: `/var/lib/reticulum/venv`
- Service name: `reticulum`

Usage:

```bash
sudo ./update_reticulum.sh /dev/ttyUSB0
```

Notes:

- The script runs `pip` and `rnodeconf` as the `reticulum` user.
- If the update path fails, the `EXIT` trap attempts to restart the `reticulum` service.

## Quick Start

1. Review the script you plan to run and confirm its hard-coded defaults match your host.
1. Make sure no other process is using the target serial device.
1. Run the built-in help for the script:

```bash
./update_meshcore.sh --help
./update_meshtastic.sh --help
./update_reticulum.sh --help
```

1. Run the updater against the correct serial port.

## Safety Notes

- These scripts perform destructive flash operations. Double-check the serial device path before running them.
- `update_meshcore.sh` and `update_reticulum.sh` stop host services as part of the update flow.
- `update_reticulum.sh` writes to `/var/log` and requires elevated privileges.
- `update_meshtastic.sh` always flashes the latest matching release; it does not compare the currently installed Meshtastic firmware version before flashing.

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
```

If a script's defaults do not match your machine, edit the variables near the top of that script before using it.
