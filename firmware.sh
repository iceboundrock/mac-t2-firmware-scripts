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
		usage: $0 [-ivhx] [subcommand] [subcmd args]

		Subcommands (the default is export_local on macOS, install_local on Linux):
		export_local [output_dir]              macOS: write renamed firmware.tar to output_dir
		install_local [path_to_archive_or_dir]  Linux: install from a firmware.tar, raw tar or directory

		Environment:
		FIRMWARE_SRC  firmware tree export_local reads (default /usr/share/firmware)

		Flags:
		-i  never prompt: install_local fails without a path instead of asking
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

# One action per platform, so the subcommand may be left out.
if [[ "$subcmd" = "" ]]; then
	case "$os" in
		(Darwin) subcmd="export_local" ;;
		(Linux) subcmd="install_local" ;;
	esac
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

# iMac19,1, iMac19,2 and iMacPro1,1 load their 4364b2 firmware under these two generic
# names. nvram_txcap_quirk picks the right pair out of the firmware tree, but it needs
# ioreg, so it only works on macOS.
TXCAP_FILES=(brcmfmac4364b2-pcie.txt brcmfmac4364b2-pcie.txcap_blob)

needs_txcap_quirk() {
	[[ $1 = iMac19,1 || $1 = iMac19,2 || $1 = iMacPro1,1 ]]
}

tree_has_txcap_files() {
	local name
	for name in "${TXCAP_FILES[@]}"; do
		[[ -f "$1/$name" ]] || return 1
	done
}

# True if every TXCAP_FILES entry is a top-level member of the archive, which is where
# it has to be for 'tar -xC /lib/firmware/brcm' to put it where the driver looks.
archive_has_txcap_files() {
	local members name
	members=$(tar -tf "$1") || return 1
	for name in "${TXCAP_FILES[@]}"; do
		grep -qxE "(\./)?${name//./\\.}" <<< "$members" || return 1
	done
}

create_firmware_archive() {
	local firmware_tree=$1
	local archive=$2
	rename_firmware "$firmware_tree" "$archive" ${verbose}
	if [[ "$os" = "Darwin" ]] && needs_txcap_quirk "$(model_identifier)"; then
		nvram_txcap_quirk "$firmware_tree" "$archive"
	elif tree_has_txcap_files "$firmware_tree"; then
		# The upstream script's EFI step put the pair it picked on macOS at the root of
		# firmware-raw.tar.gz. Keep it, as upstream's get_from_efi did; the renamer only
		# looks at wifi/ and bluetooth/ and would drop it.
		tar --append ${verbose} -f "$archive" -C "$firmware_tree" "${TXCAP_FILES[@]}"
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

# Reads /usr/share/firmware, or FIRMWARE_SRC when set (for example a mounted volume
# from another Mac). The txcap quirk still goes by the Mac running the script.
export_local() {
	local target_dir="${1:-$HOME/Downloads/apple-firmware-export}"
	local src_dir="${FIRMWARE_SRC:-/usr/share/firmware}"
	python_check
	if [[ ! -d "$src_dir" ]]; then
		echo "Error: Firmware source '$src_dir' is not a directory."
		exit 1
	fi
	echo -e "\nExporting firmware archive from $src_dir to: $target_dir"
	# Build in scratch space and move the archive into place only once it has passed
	# the check install_local applies, so a failed export leaves no firmware.tar
	# behind and does not overwrite an earlier good one.
	local workdir
	workdir=$(mktemp -d)
	CLEANUP_PATHS+=("$workdir")
	create_firmware_archive "$src_dir" "$workdir/firmware.tar"
	check_txcap_files "$workdir/firmware.tar"
	mkdir -p "$target_dir"
	mv ${verbose} "$workdir/firmware.tar" "$target_dir/firmware.tar"
	cat <<- EOF

	Firmware tarball successfully saved to:
	  $target_dir/firmware.tar

	You can copy this file or directory to a USB drive and run this script on Linux
	using option 'install_local'.
	EOF
}

# Appends the NVRAM and txcap files macOS chose for this Mac to the archive under the
# generic names in TXCAP_FILES. ioreg lists the chosen files in a RequestedFiles
# entry of the form
#   ({"Firmware"="<dir>/<x>.trx","TxCap"="<dir>/<y>.txcb",
#     "Regulatory"="<dir>/<y>.clmb","NVRAM"="<dir>/<z>.txt"})
# and the cuts below pick <y>.txcb and <z>.txt out of it. Fails rather than skipping
# the pair: without it Wi-Fi does not come up on these models, and nothing on Linux
# can pick it later.
nvram_txcap_quirk() {
	local firmware_tree="$1"
	local output_tar="$2"
	local requested nvramfile txcapblob src name stage
	requested=$(ioreg -l | grep RequestedFiles || true)
	nvramfile=$(cut -d "/" -f 5 <<< "$requested" | rev | cut -c 4- | rev)
	txcapblob=$(cut -d "/" -f 3 <<< "$requested" | cut -d "\"" -f 1)
	if [[ -z "$nvramfile" || -z "$txcapblob" ]]; then
		echo "Error: Could not read this Mac's NVRAM and txcap file names from ioreg (RequestedFiles)."
		exit 1
	fi
	src="$firmware_tree/wifi/C-4364__s-B2"
	for name in "$nvramfile" "$txcapblob"; do
		if [[ ! -f "$src/$name" ]]; then
			echo "Error: ioreg says this Mac uses $name, but $src has no such file."
			exit 1
		fi
	done
	stage=$(mktemp -d)
	CLEANUP_PATHS+=("$stage")
	cp ${verbose} "$src/$nvramfile" "$stage/brcmfmac4364b2-pcie.txt"
	cp ${verbose} "$src/$txcapblob" "$stage/brcmfmac4364b2-pcie.txcap_blob"
	tar --append ${verbose} -f "$output_tar" -C "$stage" "${TXCAP_FILES[@]}"
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

# On the txcap models an archive without both generic files at its top level leaves
# Wi-Fi broken. export_local and install_local both run this on the archive they are
# about to hand over, so neither reports success without the pair.
check_txcap_files() {
	local archive=$1
	local identifier
	identifier=$(model_identifier)
	needs_txcap_quirk "$identifier" || return 0
	archive_has_txcap_files "$archive" && return 0
	cat <<- EOF
	Error: $identifier needs brcmfmac4364b2-pcie.txt and brcmfmac4364b2-pcie.txcap_blob at
	the top level of the firmware archive, and this archive lacks them.
	EOF
	if [[ "$os" = Linux ]]; then
		cat <<- EOF
		Only macOS can pick them out (it needs ioreg). Run 'bash firmware.sh export_local'
		on macOS on this model and install the firmware.tar it writes.
		EOF
	fi
	exit 1
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