# mac-t2-firmware-scripts

## What is this

Wi-Fi will not work out of the box during or after Linux installation because the required firmware is proprietary and cannot be redistributed by any Linux distro (e.g., CachyOS). You will need an internet connection (e.g., Ethernet, USB tethering) for the installation process unless you follow the steps below to prepare the Wi-Fi firmware beforehand and enable it during installation.

This script extracts the Wi-Fi (and, on macOS Monterey or later, Bluetooth) firmware from macOS, renames the files the way the Linux `brcmfmac` driver expects, and installs them to `/lib/firmware/brcm`.

## Original Script

The original script can be downloaded from [here](https://wiki.t2linux.org/tools/firmware.sh). `firmware.sh` and `rename_firmware.py` in this repo are a trimmed-down fork of it and keep its MIT license. The renaming logic in the Python script comes from the Asahi Linux project.

## Why this repo

1. The original script does a lot of things and it contains code to download code/script from internet which may be a security concern. It downloads and runs a Python script from GitHub to fetch a macOS recovery image, falls back to downloading itself from wiki.t2linux.org, and offers to run the Homebrew installer via `curl | bash`. It also installs missing packages for you with `sudo apt`/`dnf`/`pacman` or AUR `makepkg`.
2. The original script uses the EFI partition as a temp storage for the firmware, I don't want a script messing with my EFI partition.
3. The original script has a python script embedded which is easy to distribute but hard to read. It now lives in `rename_firmware.py`.
4. The original script contains code to build installer packages (deb, rpm, pacman) for various Linux distros which I don't think are necessary.
5. The original script can mount the macOS APFS partition from Linux and read the firmware from there. That needs the out-of-tree `linux-apfs-rw` driver, which the CachyOS live ISO doesn't have and which you can't install without the network you are trying to get. It also skips the `txcap` fix for iMac19,1/19,2 and iMacPro1,1, because that fix needs `ioreg` on macOS. A USB drive covers the same case, so that path is gone.

What's left: on macOS, export the renamed firmware as a tarball to a folder or USB drive. On Linux, install from that tarball. Nothing is downloaded and no packages are installed on your behalf.

## Usage

Both `firmware.sh` and `rename_firmware.py` are needed on macOS and on Linux, so copy the whole repo to the USB drive. Run the script from the repo directory: it calls `python3 rename_firmware.py` by relative path. `python3` is required on both sides (on macOS, `xcode-select --install` provides it if it is missing).

### Extract from macOS

While still in macOS, open Terminal, `cd` into this repo and run:

```sh
bash firmware.sh export_local /Volumes/<your usb drive>/apple-firmware
```

This reads `/usr/share/firmware`, renames the files and writes `firmware.tar` to the given directory. Without an argument it writes to `~/Downloads/apple-firmware-export/`.

In special cases you can point it at a different firmware tree, such as a mounted volume from another Mac, with `FIRMWARE_SRC=/Volumes/<other mac>/usr/share/firmware bash firmware.sh export_local ...`. The `txcap` fix for iMac19,1, iMac19,2 and iMacPro1,1 still goes by the Mac running the script, so for those models export on the model itself. On those models, if it cannot find the pair the export fails rather than hand you an archive that `install_local` will refuse: it writes no new `firmware.tar`, and a `firmware.tar` already in the output directory is left as it was, so don't mistake an earlier export for this one.

Bluetooth firmware is only included from macOS Monterey (12) or later, and is only needed by MacBookPro15,4, MacBookPro16,3 and MacBookAir9,1. On other models or older macOS you only get Wi-Fi firmware, which is fine.

### Install to Linux

Boot the CachyOS live ISO (or the installed system), mount the USB drive, `cd` into the repo copy and run:

```sh
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
bash firmware.sh install_local /mnt/usb/apple-firmware/firmware.tar
sudo umount /mnt/usb
```

`install_local` extracts the tarball into `/lib/firmware/brcm` (creating it if missing) and reloads the `brcmfmac` driver, plus `hci_bcm4377` on the three models that use Bluetooth firmware. If a driver cannot be unloaded or loaded again (the module is in use, say), the files are installed but the running driver is not using them, so the script says so and exits non-zero instead of reporting success; a reboot loads the driver with the new firmware. Nothing runs under `sudo` until the input has passed the checks below. It also accepts a directory (a copy of `/usr/share/firmware`), a raw `.tar`, or the `firmware-raw.tar.gz` produced by the original script's EFI step, and runs the renaming step first in those cases. An archive is extracted first and counts as already renamed only if that leaves a `brcmfmac*.bin` at its top level, where the driver looks; otherwise it is treated as a raw tree. If you have mounted the macOS volume yourself, you can point it at `<mountpoint>/usr/share/firmware`.

Two inputs are refused rather than installed. One is a path with no usable Wi-Fi firmware under it: a mistyped directory, say, or an archive whose `brcmfmac*.bin` files sit in a subdirectory and would land where the driver does not look. Either would otherwise install and still report success. The other is any input on iMac19,1, iMac19,2 and iMacPro1,1 that lacks `brcmfmac4364b2-pcie.txt` or `brcmfmac4364b2-pcie.txcap_blob` as a regular file; the archive is extracted and inspected, so a symlink or an empty file under that name does not count. Those models load the firmware under these generic names, and picking the right pair out of the tree needs `ioreg`, so only macOS can produce them: `export_local` run on the model itself, or the original script's EFI step, which put the pair at the root of its `firmware-raw.tar.gz` (`install_local` keeps it when renaming that archive). Any other directory or raw tar renamed on Linux will not work on those models.

Then switch NetworkManager to the iwd backend:

```sh
cat <<EOF | sudo tee /etc/NetworkManager/conf.d/wifi_backend.conf
[device]
wifi.backend=iwd
EOF
sudo systemctl restart NetworkManager
```

## Subcommands

```
usage: firmware.sh [-ivhx] [subcommand] [subcmd args]
```

| Subcommand | Platform | What it does |
|---|---|---|
| `export_local [output_dir]` | macOS | Write renamed `firmware.tar` to `output_dir` (default `~/Downloads/apple-firmware-export`), reading `/usr/share/firmware` or `$FIRMWARE_SRC` |
| `install_local [path]` | Linux | Install from a `.tar`, `.tar.gz`, `.tgz` or directory; prompts for the path if omitted |

Flags: `-i` never prompt (`install_local` fails instead of asking for a path), `-v` verbose, `-x` trace with `set -x`, `-h` help. The subcommand is optional: with none, the script runs `export_local` on macOS and `install_local` on Linux.

## Tests

```sh
bash tests/run.sh                       # on a Mac, against /usr/share/firmware
bash tests/run.sh --synthetic           # on macOS or Linux, against a generated stand-in
FIRMWARE_SRC=<tree> bash tests/run.sh   # against another tree, such as another Mac's volume
```

The suite needs `bash` and `python3`. It builds its inputs at run time from a firmware tree, since nothing proprietary is checked in: `/usr/share/firmware`, the tree `FIRMWARE_SRC` names, or with `--synthetic` a stand-in that `tests/synth-tree.sh` writes, with Apple's file names, the real tree's symlinks and hard links, and throwaway contents. `--synthetic` refuses to run with `FIRMWARE_SRC` set rather than pick one tree over the other. It runs `export_local` and `install_local` with `uname`, `sudo`, `system_profiler`, `ioreg`, `sw_vers` and the `/sys/class/dmi/id/product_name` read replaced by the scripts in `tests/mocks/`, so both sides can be checked on one machine. Each case asserts the exit code, a message, what would have reached `sudo` (nothing for a refused input; for an accepted one the `mkdir` if the host has no `/lib/firmware/brcm`, then a single `tar` of an archive with the expected member names and contents, then only `modprobe`), and that every temporary directory it made is gone; `mktemp` is wrapped to record them, so other processes' temporary files cannot fail a case. The machine each case runs as comes from the mocks (MacBookPro15,1 for the plain macOS cases, iMac19,1 and MacBookPro16,3 for the `txcap` and Bluetooth paths), so the results do not depend on the host. The exception is one export that runs as the Mac itself and expects success; on iMac19,1, iMac19,2 or iMacPro1,1 that also checks the real `ioreg` answer, which may name files the synthetic tree lacks, so use the real tree there. Off macOS that case is skipped. Everything is written under one temporary directory. Against the real tree a run takes about 45 seconds and puts about 600MB there (three copies of the firmware tree, the archives built from them, and the exports); against the synthetic one, about 10 seconds and 3MB. The directory is removed at exit when every check passed. When one failed, that case prints its output inline, and the directory is kept with its path printed so the per-case output and `sudo` logs under `out/` and the fixtures can be inspected; remove it when done.

CI runs `--synthetic` on Ubuntu and macOS for every pull request and push to `main`, so `install_local` is also checked with GNU tar, the tar it meets on Linux, and `export_local` with bsdtar. Only a real tree can show that a macOS release changed it in a way the renamer does not handle. GitHub's macOS runners ship one, so the `real tree` workflow runs `bash tests/run.sh` against the runner's `/usr/share/firmware` every Monday, on whatever macOS `macos-latest` has then, and prints that release first. A scheduled run that fails on a commit an earlier run passed on means the runner's macOS changed the tree. The workflow runs on a pull request only when the pull request changes it, so after changing `firmware.sh` or `rename_firmware.py`, still run the suite on a Mac against its own tree, or run the workflow for your branch with `gh workflow run real-tree.yml --ref <branch>`.

Not covered: real privilege, and whether `modprobe` reloads the driver on actual hardware.

## License

MIT. See [LICENSE](LICENSE). The original authors' copyright notices from the upstream script are preserved there.
