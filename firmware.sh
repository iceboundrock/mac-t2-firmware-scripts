#!/usr/bin/env bash

# Copyright (C) 2024 Aditya Garg <gargaditya08@live.com>
# Copyright (C) 2024 Orlando Chamberlain <redecorating@protonmail.com>
# Copyright (C) 2024 Sharpened Blade <sharpenedblade@proton.me>
#
# The python script is based upon the original work by The Asahi Linux Contributors.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

rename_firmware () {
	python3 rename_firmware.py "$@" 
}

set -euo pipefail

# Register temporary paths to clean up on script exit
CLEANUP_PATHS=()
cleanup() {
	for p in "${CLEANUP_PATHS[@]-}"; do
		if [ -d "$p" ] || [ -f "$p" ]; then
			rm -rf "$p" 2>/dev/null || true
		fi
	done
}
trap cleanup EXIT INT TERM

verbose=""
subcmd=""
args=()
interactive="true"

while getopts "ivhx" option; do
	case $option in
		i) interactive="false" ;;
		v) verbose="-v" ;;
		h)
		cat <<- EOF
		usage: $0 [-ivhx] subcommand [subcmd args]

		Subcommands:
		export_local [output_dir]
		create_archive
		install_local [path_to_archive_or_dir]
		rename_only /path/to/firmware archive.tar

		Flags:
		-i  never prompt: no menu on macOS, and install_local fails without a path
		-v  verbose
		-x  trace with set -x
		-h  this help
		EOF
		exit 0 ;;
		x) set -x;;
		?) exit 1 ;; 
	esac
done

shift $((OPTIND - 1))

subcmd="${1-}"
if [[ $# -gt 0 ]]; then
	args=( "${@:2}" )
fi

os=$(uname -s)

if [[ "$subcmd" = "" ]]; then
	case "$os" in
		(Darwin)
			if [[ "$interactive" = "true" ]]; then
				echo "Detected macOS"
				cat <<- EOF

				How do you want to extract the firmware?

				1. Export firmware tarball to a local directory / USB drive.
				2. Create a tarball in Downloads ($HOME/Downloads/firmware.tar).

				EOF
				read -rp "Enter choice [1-2]: " choice
				case ${choice} in
					(1) subcmd="export_local" ;;
					(2) subcmd="create_archive" ;;
					(*) echo -e "\nError: Invalid option!" && exit 1 ;;
				esac
			fi
			;;
		(Linux)
			# install_local is the only Linux subcommand, so it is the default with or
			# without -i. Without a path it prompts, or under -i fails.
			echo "Detected Linux"
			subcmd="install_local"
			;;
		(*)
			echo "Error: Unsupported platform: $os"
			exit 1
			;;
	esac
fi

if [[ "$subcmd" = "" ]]; then
	echo "Error: No subcommand specified."
	exit 1
fi

python_check () {
	if ! command -v python3 >/dev/null 2>&1; then
		echo "Error: Python 3 is required but not installed."
		exit 1
	fi
}

model_identifier() {
	case "$os" in
		(Darwin) system_profiler SPHardwareDataType | grep "Model Identifier" | cut -d ":" -f 2 | xargs || true ;;
		(Linux) cat /sys/class/dmi/id/product_name 2>/dev/null || true ;;
	esac
}

# These models load brcmfmac4364b2-pcie.txt and brcmfmac4364b2-pcie.txcap_blob under
# those generic names. nvram_txcap_quirk picks the right pair out of the firmware
# tree, but it needs ioreg, so it only works on macOS.
needs_txcap_quirk() {
	[[ $1 = iMac19,1 || $1 = iMac19,2 || $1 = iMacPro1,1 ]]
}

create_firmware_archive() {
	local firmware_tree=$1
	local archive=$2
	rename_firmware "$firmware_tree" "$archive" ${verbose}
	if [[ "$os" = "Darwin" ]] && needs_txcap_quirk "$(model_identifier)"; then
		nvram_txcap_quirk "$firmware_tree" "$archive"
	fi
}

reload_kernel_modules () {
	echo "Reloading Wi-Fi and Bluetooth drivers..."
	sudo modprobe -r ${verbose} brcmfmac_wcc 2>/dev/null || true
	sudo modprobe -r ${verbose} brcmfmac 2>/dev/null || true
	sudo modprobe ${verbose} brcmfmac || true
	sudo modprobe -r ${verbose} hci_bcm4377 2>/dev/null || true
	sudo modprobe ${verbose} hci_bcm4377 || true
}

export_local() {
	local target_dir="${1:-$HOME/Downloads/apple-firmware-export}"
	python_check
	mkdir -p "$target_dir"
	echo -e "\nExporting firmware archive to: $target_dir"
	create_firmware_archive /usr/share/firmware "$target_dir/firmware.tar"
	cat <<- EOF

	Firmware tarball successfully saved to:
	  $target_dir/firmware.tar

	You can copy this file or directory to a USB drive and run this script on Linux
	using option 'install_local'.
	EOF
}

nvram_txcap_quirk() {
	local firmware_tree="$1"
	local output_tar="$2"
	local nvramfile
	local txcapblob
	nvramfile=$(ioreg -l | grep RequestedFiles | cut -d "/" -f 5 | rev | cut -c 4- | rev || true)
	txcapblob=$(ioreg -l | grep RequestedFiles | cut -d "/" -f 3 | cut -d "\"" -f 1 || true)
	if [[ -n "$nvramfile" && -n "$txcapblob" && -f "${firmware_tree}/wifi/C-4364__s-B2/${nvramfile}" ]]; then
		cp ${verbose} "${firmware_tree}/wifi/C-4364__s-B2/${nvramfile}" brcmfmac4364b2-pcie.txt
		cp ${verbose} "${firmware_tree}/wifi/C-4364__s-B2/${txcapblob}" brcmfmac4364b2-pcie.txcap_blob
		tar --append ${verbose} -f "$output_tar" brcmfmac4364b2-pcie.txt brcmfmac4364b2-pcie.txcap_blob
		rm ${verbose} brcmfmac4364b2-pcie.txt brcmfmac4364b2-pcie.txcap_blob
	fi
}

# True if the tar already holds renamed firmware (brcmfmac*.bin) rather than a raw
# macOS firmware tree. A raw tree has .trx files, and on the txcap models the
# upstream script's raw tar also carries brcmfmac4364b2-pcie.txt at its root, so
# matching on the name alone would misfile it. The listing is captured first so
# grep -q quitting early cannot fail the pipeline under pipefail.
archive_has_wifi_firmware() {
	local members
	members=$(tar -tf "$1" 2>/dev/null) || return 1
	grep -q 'brcmfmac.*\.bin$' <<< "$members"
}

# On the txcap models an archive without the two generic files leaves Wi-Fi broken,
# and only export_local on macOS can produce them. Refuse rather than install it
# and report success.
check_txcap_files() {
	local archive=$1
	local identifier
	identifier=$(model_identifier)
	needs_txcap_quirk "$identifier" || return 0
	local members
	members=$(tar -tf "$archive")
	if ! grep -q 'brcmfmac4364b2-pcie\.txcap_blob$' <<< "$members"; then
		cat <<- EOF
		Error: $identifier needs brcmfmac4364b2-pcie.txt and brcmfmac4364b2-pcie.txcap_blob,
		which this script can only pick out on macOS (it needs ioreg). Run
		'bash firmware.sh export_local' on macOS and install the firmware.tar it writes.
		EOF
		exit 1
	fi
}

install_local() {
	local src_path="${1-}"
	python_check

	if [[ -z "$src_path" ]]; then
		if [[ "$interactive" = "false" ]]; then
			echo "Error: install_local needs the path to a firmware archive or directory when run with -i."
			exit 1
		fi
		read -rp "Enter path to firmware file/folder (e.g. /mnt/usb/firmware.tar): " src_path
	fi

	if [[ ! -e "$src_path" ]]; then
		echo "Error: Path '$src_path' does not exist."
		exit 1
	fi

	local workdir
	workdir=$(mktemp -d)
	CLEANUP_PATHS+=("$workdir")
	local archive="$workdir/firmware-renamed.tar"

	echo -e "\nProcessing local firmware from: $src_path"

	if [[ -d "$src_path" ]]; then
		create_firmware_archive "$src_path" "$archive"
	elif [[ "$src_path" == *.tar ]]; then
		if archive_has_wifi_firmware "$src_path"; then
			cp "$src_path" "$archive"
		else
			tar -xf "$src_path" -C "$workdir"
			create_firmware_archive "$workdir" "$archive"
		fi
	elif [[ "$src_path" == *.tar.gz || "$src_path" == *.tgz ]]; then
		tar -xzf "$src_path" -C "$workdir"
		create_firmware_archive "$workdir" "$archive"
	else
		echo "Error: Unsupported file format. Please provide a directory or .tar / .tar.gz archive."
		exit 1
	fi

	check_txcap_files "$archive"

	echo "Installing firmware files to /lib/firmware/brcm..."
	sudo tar ${verbose} -xC /lib/firmware/brcm -f "$archive"
	reload_kernel_modules
	echo -e "\nDone! Firmware installation complete."
}

case "$os" in
	(Darwin)
		ver=$(sw_vers -productVersion)
		ver_check=$(sw_vers -productVersion | cut -d "." -f 1)
		identifier=$(model_identifier)
		if [[ ${ver_check} -lt 12 ]] && [[ (${identifier} = MacBookPro15,4) || (${identifier} = MacBookPro16,3) || (${identifier} = MacBookAir9,1) ]]; then
			cat <<- EOF

			Warning: You are running a macOS version earlier than macOS Monterey.
			Bluetooth firmware requires macOS Monterey or later.
			Only Wi-Fi firmware shall be exported.

			EOF
		fi
		case ${subcmd} in
			("export_local")
				export_local "${args[0]-}"
				;;
			("create_archive")
				python_check
				echo -e "\nCreating firmware archive in Downloads..."
				create_firmware_archive /usr/share/firmware "$HOME/Downloads/firmware.tar"
				echo "Saved to $HOME/Downloads/firmware.tar"
				;;
			("rename_only")
				rename_firmware "${args[@]}" ${verbose}
				;;
			(*)
				echo "Error: Invalid option '$subcmd'!"
				exit 1
				;;
		esac
		;;

	(Linux)
		if [[ ! -d /lib/firmware/brcm ]]; then
			echo "Creating /lib/firmware/brcm directory..."
			sudo mkdir -p /lib/firmware/brcm
		fi
		case ${subcmd} in
			("install_local")
				install_local "${args[0]-}"
				;;
			(*)
				echo "Error: Invalid option '$subcmd'!"
				exit 1
				;;
		esac
		;;
	(*)
		echo "Error: Unsupported platform '$os'"
		exit 1
		;;
esac
exit 0