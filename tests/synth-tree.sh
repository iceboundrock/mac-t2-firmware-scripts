#!/usr/bin/env bash
# Writes a stand-in for /usr/share/firmware into the directory given as $1, which must
# not exist, so run.sh can run without Apple's tree (run.sh --synthetic). The names
# follow the real tree's; the contents are throwaway.
#
# It copies the shape the scripts meet in the real tree, in miniature:
# - Under wifi/, the chip directories the renamer reads, each with regular base files
#   per platform and the antenna variants (-ID, -X0, -X2, -X3) as relative symlinks to
#   them, one platform's .trx a symlink to another's, and some NVRAM revisions hard
#   links of each other. The renamer collapses the identical variants and writes
#   duplicate contents as hard-link members, so tar meets symlinks and hard links in the
#   raw-tree fixtures and hard links in the renamed archive, as with the real tree.
# - wifi/C-4364__s-B2 has kauai-X3.txcb and P-kauai-X3*.txt, for the fake iMac19,1.
# - Files the renamer skips: a chip directory it does not read, a .plist under wifi/,
#   and _DEV, .hex and .dfu files under bluetooth/.
# - Bluetooth .bin/.ptb pairs in both name forms (PCIE_<board> and PCIE_macOS_<board>),
#   with each vendor tag (GEN, MUR, USI), an ES2 board suffix, and a MUR/USI .ptb pair
#   hard-linked as in the real tree. No two map to the same chip, board and vendor: the
#   renamer keeps whichever os.listdir returns first, and nothing guarantees that the
#   copies build-fixtures.sh makes list in the same order as this tree.
# Every regular file has contents of its own (its path), so files differ unless linked.
set -euo pipefail

mkdir "$1"
cd "$1"

# regular <path>: a regular file holding its own path. NVRAM files (.txt) are key=value
# lines, which the renamer requires.
regular() {
	mkdir -p "$(dirname "$1")"
	case $1 in
		(*.txt) printf 'boardtype=0x07bf\nsynthetic=%s\n' "$1" > "$1" ;;
		(*) printf 'synthetic %s\n' "$1" > "$1" ;;
	esac
}

# platform <chip dir> <platform> <module> <revision>...: the platform's .trx, .clmb and
# .txcb, NVRAM files named P-<platform>_M-<module>_<revision>.txt, and every antenna
# variant of each as a symlink to it. A revision is V-<vendor>__m-<version>.
platform() {
	local dir=$1 plat=$2 module=$3 ext rev ant; shift 3
	for ext in trx clmb txcb; do regular "$dir/$plat.$ext"; done
	for rev in "$@"; do regular "$dir/P-${plat}_M-${module}_$rev.txt"; done
	for ant in ID X0 X2 X3; do
		for ext in trx clmb txcb; do
			ln -s "$plat.$ext" "$dir/$plat-$ant.$ext"
		done
		for rev in "$@"; do
			ln -s "P-${plat}_M-${module}_$rev.txt" "$dir/P-$plat-${ant}_M-${module}_$rev.txt"
		done
	done
}

B2=wifi/C-4364__s-B2
platform "$B2" ekans HRPN V-m__m-6.1 V-m__m-6.3 V-m__m-7.3 V-u__m-6.1
platform "$B2" kauai HRPN V-m__m-6.1 V-u__m-6.1
# kauai runs ekans's firmware, and two of ekans's NVRAM revisions are one file.
ln -sf ekans.trx "$B2/kauai.trx"
ln -f "$B2/P-ekans_M-HRPN_V-m__m-6.3.txt" "$B2/P-ekans_M-HRPN_V-m__m-7.3.txt"
platform wifi/C-4364__s-B3 bali HRPN V-m__m-7.9 V-u__m-7.7
platform wifi/C-4377__s-B3 formosa SPPR V-m__m-3.1 V-u__m-3.1
platform wifi/C-4378__s-B1 capri HRPN V-m__m-6.1
regular wifi/kauai-PlatformConfig.plist

BT=bluetooth
regular "$BT/BCM4377B3_97.93.153_PCIE_Formosa_MFG_GEN_20230208_PROD.signed.bin"
regular "$BT/BCM4377B3__PCIE_Formosa_MFG_GEN__PRODK_R_.ptb"
regular "$BT/BCM4377B3_97.93.153_PCIE_Formosa_MFG_GEN_20230208_DEV.signed.bin"
regular "$BT/BCM4377B3__PCIE_Formosa_MFG_GEN__DEVK_R_.ptb"
regular "$BT/BCM4378B1_22.5.539.3927_PCIE_macOS_Honshu_OS_MUR_20241009.bin"
regular "$BT/BCM4378B1_22.5.539.3928_PCIE_macOS_Honshu_OS_USI_20241009.bin"
regular "$BT/BCM4378B1_FinalV0_PCIE_macOS_Honshu_OS_MUR_K_R_2020824.ptb"
ln "$BT/BCM4378B1_FinalV0_PCIE_macOS_Honshu_OS_MUR_K_R_2020824.ptb" "$BT/BCM4378B1_FinalV0_PCIE_macOS_Honshu_OS_USI_K_R_2020824.ptb"
regular "$BT/BCM4387C2_22.5.614.3433_PCIE_macOS_HokkaidoES2_CLPC_OS_USI_20250129.bin"
regular "$BT/BCM4387C2_Final_PCIE_macOS_HokkaidoES2_CLPC_OS_USI_K_R_202120317.ptb"
regular "$BT/BCM4364B3-MiniDriver-uart.hex"
regular "$BT/20702_8289.dfu"
