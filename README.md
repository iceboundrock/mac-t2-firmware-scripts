# mac-t2-firmware-scripts

## What is this

Wi-Fi will not work out of the box during or after installation because the required firmware is proprietary and cannot be redistributed by any Linux distro (e.g., CachyOS). You will need an internet connection (e.g., Ethernet, USB tethering) for the installation process unless you follow the steps below to prepare the Wi-Fi firmware beforehand and enable it during installation.

This script extracts the Wi-Fi (and, on macOS Monterey or later, Bluetooth) firmware from macOS, renames the files the way the Linux `brcmfmac` driver expects, and installs them to `/lib/firmware/brcm`.

## Original Script

The original script can be downloaded from [here](https://wiki.t2linux.org/tools/firmware.sh). `firmware.sh` and `rename_firmware.py` in this repo are a trimmed-down fork of it and keep its MIT license. The renaming logic in the Python script comes from the Asahi Linux project.

## Why this repo

1. The original script does a lot of things and it contains code to download code/script from internet which may be a security concern. It downloads and runs a Python script from GitHub to fetch a macOS recovery image, falls back to downloading itself from wiki.t2linux.org, and offers to run the Homebrew installer via `curl | bash`. It also installs missing packages for you with `sudo apt`/`dnf`/`pacman` or AUR `makepkg`.
2. The original script uses the EFI partition as a temp storage for the firmware, I don't want a script messing with my EFI partition.
3. The original script has a python script embedded which is easy to distribute but hard to read. It now lives in `rename_firmware.py`.
4. The original script contains code to build installer packages (deb, rpm, pacman) for various Linux distros which I don't think are necessary.

What's left: on macOS, export the renamed firmware as a tarball to a folder or USB drive. On Linux, install from that tarball, or read it directly from the macOS APFS partition. Nothing is downloaded and no packages are installed on your behalf.

## Usage

Both `firmware.sh` and `rename_firmware.py` are needed on macOS and on Linux, so copy the whole repo to the USB drive. Run the script from the repo directory: it calls `python3 rename_firmware.py` by relative path. `python3` is required on both sides (on macOS, `xcode-select --install` provides it if it is missing).

### Extract from macOS

While still in macOS, open Terminal, `cd` into this repo and run:

```sh
bash firmware.sh export_local /Volumes/<your usb drive>/apple-firmware
```

This reads `/usr/share/firmware`, renames the files and writes `firmware.tar` to the given directory. Without an argument it writes to `~/Downloads/apple-firmware-export/`.

Bluetooth firmware is only included from macOS Monterey (12) or later, and is only needed by MacBookPro15,4, MacBookPro16,3 and MacBookAir9,1. On other models or older macOS you only get Wi-Fi firmware, which is fine.

### Install to Linux

Boot the CachyOS live ISO (or the installed system), mount the USB drive, `cd` into the repo copy and run:

```sh
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
bash firmware.sh install_local /mnt/usb/apple-firmware/firmware.tar
sudo umount /mnt/usb
```

`install_local` extracts the tarball into `/lib/firmware/brcm` and reloads the `brcmfmac` and `hci_bcm4377` kernel modules. It also accepts a directory (a copy of `/usr/share/firmware`), a raw `.tar`, or the `firmware-raw.tar.gz` produced by the original script's EFI step, and runs the renaming step first in those cases.

Then switch NetworkManager to the iwd backend:

```sh
cat <<EOF | sudo tee /etc/NetworkManager/conf.d/wifi_backend.conf
[device]
wifi.backend=iwd
EOF
sudo systemctl restart NetworkManager
```

### Alternative: read the firmware from the macOS partition in Linux

If you skipped the macOS step, Linux can read the firmware directly from the APFS volume on the same disk:

```sh
bash firmware.sh get_from_macos
```

This needs the APFS kernel module ([linux-apfs-rw](https://github.com/linux-apfs/linux-apfs-rw), `linux-apfs-rw-dkms-git` on the AUR). The script does not install it for you. It mounts the first APFS partition `lsblk` reports, looks for `usr/share/firmware` in its volumes, installs the firmware, reloads the drivers and unmounts.

## Subcommands

```
usage: firmware.sh [-ivhx] subcommand [subcmd args]
```

| Subcommand | Platform | What it does |
|---|---|---|
| `export_local [output_dir]` | macOS | Write renamed `firmware.tar` to `output_dir` (default `~/Downloads/apple-firmware-export`) |
| `create_archive` | macOS | Write renamed `firmware.tar` to `~/Downloads` |
| `rename_only <firmware_dir> <archive.tar>` | macOS | Only run the renaming step on a firmware tree |
| `install_local [path]` | Linux | Install from a `.tar`, `.tar.gz` or directory; prompts for the path if omitted |
| `get_from_macos` | Linux | Mount the local APFS volume and install from it |

Flags: `-i` skip the interactive menu, `-v` verbose, `-x` trace with `set -x`, `-h` help. With no subcommand the script shows a menu for the current OS.

## License

MIT. See [LICENSE](LICENSE). The original authors' copyright notices from the upstream script are preserved there.
