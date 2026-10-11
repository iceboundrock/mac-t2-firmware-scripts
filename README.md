# mac-t2-firmware-scripts

## What is this

Wi-Fi will not work out of the box during or after installation because the required firmware is proprietary and cannot be redistributed by any Linux distro (e.g.,  CachyOS). You will need an internet connection (e.g., Ethernet, USB tethering) for the installation process unless you follow the steps below to prepare the Wi-Fi firmware beforehand and enable it during installation.

This script can extract the firmware from macOS and configure Linux network manager to use the firmware.

## Original Script

The original script can be downloaded from [here](https://wiki.t2linux.org/tools/firmware.sh)

## Why this repo

1. The original script does a lot of things and it contains code to download code/script from internet which may be a security concern.
2. The original script uses the EFI partition as a temp storage for the firmware, I don't want a script mess up with my EFI partition.
3. The original script has a python script embeded which is easy to distribute but hard to read
4. The original script contains code to build installer packages for various Linux distro which I don't think they are necessary 


## Usage

### Extract from macOS

While still in macOS, open Terminal and run the following command. This copies the necessary Wi-Fi firmware files to your EFI partition, making them accessible later during the CachyOS installation.

```sh
firmware.sh export_local
```

### Install to Linux


```sh
sudo /tmp/apple-wifi-efi
sudo mount <your usb drive> /tmp/apple-wifi-efi
bash /tmp/apple-wifi-efi/firmware.sh get_from_efi
sudo umount /tmp/apple-wifi-efi
cat <<EOF | sudo tee /etc/NetworkManager/conf.d/wifi_backend.conf
[device]
wifi.backend=iwd
EOF
sudo systemctl restart NetworkManager
```