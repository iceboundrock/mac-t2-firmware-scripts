#!/usr/bin/env bash
# Runs firmware.sh through its macOS path for real, as a model the scripts in
# mocks/macos report, and through its Linux path with uname, sudo and the DMI model read
# replaced by the scripts in mocks/linux. Each case checks the exit code, a message, what
# would have been handed to sudo, and that every temp directory it made is gone
# (mocks/common/mktemp records them). build-fixtures.sh makes the inputs from this Mac's
# /usr/share/firmware at run time; nothing proprietary is checked in. Everything is
# written under one mktemp directory. It is removed at exit when every check passed; a
# failed case prints its output, and the directory is kept, with its path printed, so the
# per-case output and sudo logs under out/ and the fixtures can be inspected.
#
# Needs a Mac with /usr/share/firmware, bash and python3. Only H1 depends on which Mac
# runs the suite: the other macOS cases take their model from the mocks, and the Linux
# cases from the mocked DMI read or, without one, from the DMI file no Mac has. H1 exports
# as this Mac and expects success; on iMac19,1, iMac19,2 and iMacPro1,1 that goes through
# the real ioreg.
#
# Usage: bash tests/run.sh

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(dirname "$TESTS")
# firmware.sh calls rename_firmware.py by relative path, so it is run from the repo.
cd "$REPO" || exit 2

S=$(mktemp -d) || exit 2
pass=0; fail=0
cleanup() {
	if [ "$fail" = 0 ]; then
		rm -rf "$S"
	else
		echo "scratch kept for inspection: $S ($(du -sh "$S" | cut -f1)); remove it when done"
	fi
}
trap cleanup EXIT
F="$S/fixtures"; OUT="$S/out"; H="$S/home"
mkdir -p "$OUT" "$H"
bash "$TESTS/build-fixtures.sh" "$F" || exit 2

members() { tar -tf "$1" | wc -l | tr -d ' '; }
# members_eq <archive> <count>: true if the archive has that many members; says how many it has otherwise.
members_eq() { local got; got=$(members "$1"); [ "$got" = "$2" ] || { echo "$1 has $got members, want $2"; return 1; }; }
has_member() { tar -tf "$1" | grep -qx "$2"; }
manifest() { python3 "$TESTS/tar_manifest.py" "$1"; }
# same_contents <archive> <reference>: true if the two would install the same files with
# the same contents; prints the manifest diff otherwise (<: reference only, >: archive only).
same_contents() { diff <(manifest "$2") <(manifest "$1"); }

# run <name> <exit> <pattern> <installs> <stdin> <path-prefix> <cmd>...
#   exit      expected exit code
#   pattern   must appear in the combined stdout/stderr
#   installs  "-": nothing may run under sudo (the input was refused);
#             an archive: sudo must run "mkdir -p /lib/firmware/brcm", then one tar into
#             /lib/firmware/brcm of an archive with the same manifest as this one, then
#             nothing but modprobe (the directory never exists on a Mac, so the mkdir is
#             always seen); "": no sudo check (macOS cases)
#   stdin     fed to the command (the prompted-path case)
#   prefix    directory put first on PATH ("" for none), ahead of mocks/common
# The output goes to $OUT/<name>.out, the sudo log to $OUT/<name>.sudo, the manifest of
# what sudo tar was handed to $OUT/<name>.sudo.manifest and the paths mktemp created to
# $OUT/<name>.mktemp; each of those paths must be gone afterwards.
run() {
	local name=$1 want_exit=$2 pattern=$3 want_installed=$4 stdin=$5 prefix=$6; shift 6
	export SUDO_LOG="$OUT/$name.sudo" MKTEMP_LOG="$OUT/$name.mktemp"
	: > "$SUDO_LOG"; : > "$SUDO_LOG.manifest"; : > "$MKTEMP_LOG"
	local out status left p cmds differs="" ok=1 why="" path="$TESTS/mocks/common:$PATH"
	[ -z "$prefix" ] || path="$prefix:$path"
	out=$(printf '%s\n' "$stdin" | PATH="$path" "$@" 2>&1); status=$?
	[ "$status" = "$want_exit" ] || { ok=0; why+=" exit=$status(want $want_exit)"; }
	grep -q -- "$pattern" <<< "$out" || { ok=0; why+=" missing-pattern"; }
	if [ "$want_installed" = "-" ]; then
		[ ! -s "$SUDO_LOG" ] || { ok=0; why+=" sudo-ran:$(head -1 "$SUDO_LOG" | cut -d' ' -f2-)"; }
	elif [ -n "$want_installed" ]; then
		# Exactly one install: a second tar, or anything but a driver reload after the
		# first, fails the case even where no sudo_sequence pins the modprobe calls.
		cmds=$(cut -d' ' -f2- "$SUDO_LOG")
		if ! { [ "$(sed -n 1p <<< "$cmds")" = "mkdir -p /lib/firmware/brcm" ] &&
			sed -n 2p <<< "$cmds" | grep -q '^tar -xC /lib/firmware/brcm -f ' &&
			! sed -n '3,$p' <<< "$cmds" | grep -qv '^modprobe '; }; then
			ok=0; why+=" sudo-order:$(cut -d' ' -f1 <<< "$cmds" | tr '\n' ,)"
		fi
		differs=$(diff <(manifest "$want_installed") "$SUDO_LOG.manifest") || { ok=0; why+=" installed-differs-from:${want_installed##*/}"; }
	fi
	left=$(while IFS= read -r p; do [ ! -e "$p" ] || echo "$p"; done < "$MKTEMP_LOG")
	[ -z "$left" ] || { ok=0; why+=" tmp-left:$(tr '\n' , <<< "$left")"; }
	printf '%s\n' "$out" > "$OUT/$name.out"
	if [ $ok = 1 ]; then
		pass=$((pass+1)); echo "PASS $name"
	else
		fail=$((fail+1)); echo "FAIL $name:$why"
		sed 's/^/    | /' <<< "$out"
		[ -s "$SUDO_LOG" ] && sed 's/^/    | /' "$SUDO_LOG"
		if [ -n "$differs" ]; then
			sed 's/^/    | /' <<< "$differs" | head -20
			[ "$(wc -l <<< "$differs")" -le 20 ] || echo "    | ... (installed manifest: $SUDO_LOG.manifest)"
		fi
	fi
}
# check <name> <condition>: the condition is evaluated with this shell's variables and
# functions. On failure it is printed along with whatever it wrote (a diff, a count).
check() {
	local out
	if out=$(eval "$2" 2>&1); then
		pass=$((pass+1)); echo "PASS $1"
	else
		fail=$((fail+1)); echo "FAIL $1: $2"
		[ -z "$out" ] || sed 's/^/    | /' <<< "$out"
	fi
}
# sudo_sequence <case> <cmd>...: the sudo log must hold exactly these commands in this order (glob patterns).
sudo_sequence() {
	local name=$1 ok=1 i=0 line want; shift
	local -a got=()
	while IFS= read -r line; do got+=("${line#sudo: }"); done < <(grep '^sudo: ' "$OUT/$name.sudo")
	[ ${#got[@]} = $# ] || ok=0
	# shellcheck disable=SC2053  # the right-hand side is a glob on purpose
	for want in "$@"; do [[ "${got[i]-}" == $want ]] || ok=0; i=$((i+1)); done
	if [ $ok = 1 ]; then
		pass=$((pass+1)); echo "PASS $name:sudo-sequence"
	else
		fail=$((fail+1)); echo "FAIL $name:sudo-sequence"
		echo "    | got:  $(printf '%s | ' "${got[@]-}")"
		echo "    | want: $(printf '%s | ' "$@")"
	fi
}

ML="$TESTS/mocks/linux"; MM="$TESTS/mocks/macos"
# shellcheck disable=SC2034  # used in check conditions
TXT=brcmfmac4364b2-pcie.txt BLOB=brcmfmac4364b2-pcie.txcap_blob
SRC=/usr/share/firmware; SRC4364="$SRC/wifi/C-4364__s-B2"
KAUAI_TXT=$(cat "$F/kauai-txt-name")
sha() { shasum -a 256 | cut -d' ' -f1; }
# shellcheck disable=SC2034  # used in check conditions
KAUAI_TXT_SHA=$(sha < "$SRC4364/$KAUAI_TXT")
# shellcheck disable=SC2034
KAUAI_TXCB_SHA=$(sha < "$SRC4364/kauai-X3.txcb")
B="$F/renamed.tar"
# B plus the synthesized txcap pair at the top level: what installing any input that
# carries that pair at its root should hand to sudo tar.
BPAIR="$F/renamed-with-txcap.tar"
# Member counts follow this Mac's tree: N for renamed firmware, N+2 with the txcap pair.
N=$(members "$B")
# shellcheck disable=SC2034  # used in check conditions
N2=$((N + 2))
# Mocked identities. OTHER_MAC is a model with neither the txcap nor the Bluetooth quirk.
OTHER_MAC=(env "MOCK_MODEL=MacBookPro15,1")
IMAC=(env "MOCK_MODEL=iMac19,1" MOCK_IOREG=requested "MOCK_IOREG_NVRAM=$KAUAI_TXT" MOCK_IOREG_TXCAP=kauai-X3.txcb)
IMAC_NOIOREG=(env "MOCK_MODEL=iMac19,1" MOCK_IOREG=none)
IMAC_BADIOREG=(env "MOCK_MODEL=iMac19,1" MOCK_IOREG=requested MOCK_IOREG_NVRAM=P-nosuch-X9_M-ZZZZ_V-u__m-0.0.txt MOCK_IOREG_TXCAP=nosuch-X9.txcb)
BT_OLD_MACOS=(env "MOCK_MODEL=MacBookPro16,3" MOCK_MACOS_VERSION=11.7.10)
OTHER_OLD_MACOS=(env "MOCK_MODEL=MacBookPro15,1" MOCK_MACOS_VERSION=11.7.10)
LINUX_IMAC=(env "MOCK_DMI_MODEL=iMac19,1")
LINUX_BT=(env "MOCK_DMI_MODEL=MacBookPro16,3")
# The no-argument export cases run with HOME pointed at scratch; the real default
# output must come through untouched, whether or not it exists.
REAL_EXPORT="$HOME/Downloads/apple-firmware-export/firmware.tar"
real_export_stat() { stat -f '%m %z' "$REAL_EXPORT" 2>/dev/null || echo absent; }
# shellcheck disable=SC2034  # used in a check condition
REAL_EXPORT_BEFORE=$(real_export_stat)
echo "firmware tree: $SRC ($N renamed members); scratch: $S"

echo "== macOS on MacBookPro15,1 (mocked system_profiler) =="
run M1-help              0 "FIRMWARE_SRC"                  "" "" "$MM" "${OTHER_MAC[@]}" bash firmware.sh -h
run M2-i-no-subcmd       0 "successfully saved"            "" "" "$MM" "${OTHER_MAC[@]}" HOME="$H" bash firmware.sh -i
run M3-no-subcmd         0 "successfully saved"            "" "" "$MM" "${OTHER_MAC[@]}" HOME="$H" bash firmware.sh
run M4-export_local      0 "successfully saved"            "" "" "$MM" "${OTHER_MAC[@]}" bash firmware.sh export_local "$OUT/export"
run M5-create_archive-gone 1 "Invalid option"              "" "" "$MM" "${OTHER_MAC[@]}" bash firmware.sh create_archive
run M6-rename_only-gone  1 "Invalid option"                "" "" "$MM" "${OTHER_MAC[@]}" bash firmware.sh rename_only "$F/emptydir" "$OUT/x.tar"
run M7-src-empty         1 "no Wi-Fi firmware found"       "" "" "$MM" "${OTHER_MAC[@]}" FIRMWARE_SRC="$F/emptydir" bash firmware.sh export_local "$OUT/ov-empty"
run M8-src-missing       1 "is not a directory"            "" "" "$MM" "${OTHER_MAC[@]}" FIRMWARE_SRC="$F/nonexistent" bash firmware.sh export_local "$OUT/ov-none"
run M9-src-override      0 "from $F/rawtree-txcap"         "" "" "$MM" "${OTHER_MAC[@]}" FIRMWARE_SRC="$F/rawtree-txcap" bash firmware.sh export_local "$OUT/ov-tree"
check M10-default-dir-N      'members_eq "$H/Downloads/apple-firmware-export/firmware.tar" "$N"'
# On a model without the txcap quirk export_local adds nothing to what the renamer
# produced and changes none of it: the same members with the same contents.
check M11-export-eq-renamer  'same_contents "$OUT/export/firmware.tar" "$B"'
# A pair at the root of the source tree is carried over as it is.
check M12-override-keeps-pair 'same_contents "$OUT/ov-tree/firmware.tar" "$BPAIR"'
check M13-empty-src-no-tar   '[ ! -e "$OUT/ov-empty/firmware.tar" ]'
check M14-real-home-untouched '[ "$(real_export_stat)" = "$REAL_EXPORT_BEFORE" ]'
# The output directory may be relative to the repo, which is where the script is run from.
RELOUT=$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$OUT/rel-out" "$REPO")
run M15-relative-outdir  0 "successfully saved"            "" "" "$MM" "${OTHER_MAC[@]}" bash firmware.sh export_local "$RELOUT"
check M16-relative-outdir-N  'members_eq "$OUT/rel-out/firmware.tar" "$N"'
# A root pair that is only symlinks is not carried over; tar would store it as links.
run M17-src-symlink-pair 0 "successfully saved"            "" "" "$MM" "${OTHER_MAC[@]}" FIRMWARE_SRC="$F/rawtree-symlink-txcap" bash firmware.sh export_local "$OUT/ov-symlink"
check M18-symlink-pair-not-carried 'same_contents "$OUT/ov-symlink/firmware.tar" "$B"'
# The leftover check in run goes by the mktemp log, so the log must see firmware.sh's own calls.
check M19-mktemp-recorded    '[ -s "$OUT/M4-export_local.mktemp" ]'

echo "== macOS on this Mac (real system_profiler) =="
# The one case with this Mac's own identity. export_local refuses to write an archive that
# lacks what the model needs, so success is the expectation on any Mac; on iMac19,1,
# iMac19,2 and iMacPro1,1 it takes a pair named by the real ioreg.
run H1-this-mac-export   0 "successfully saved"            "" "" ""  bash firmware.sh export_local "$OUT/this-mac"

echo "== macOS on iMac19,1 (mocked system_profiler/ioreg) =="
run X1-imac-export       0 "successfully saved"            "" "" "$MM" "${IMAC[@]}" bash firmware.sh export_local "$OUT/imac-ok"
check X2-imac-export-N2      'members_eq "$OUT/imac-ok/firmware.tar" "$N2"'
check X3-imac-pair-top-level 'has_member "$OUT/imac-ok/firmware.tar" $TXT && has_member "$OUT/imac-ok/firmware.tar" $BLOB'
check X4-imac-picked-ioreg-files '[ "$(tar -xOf "$OUT/imac-ok/firmware.tar" $BLOB | sha)" = "$KAUAI_TXCB_SHA" ] && [ "$(tar -xOf "$OUT/imac-ok/firmware.tar" $TXT | sha)" = "$KAUAI_TXT_SHA" ]'
run X5-imac-verbose      0 "successfully saved"            "" "" "$MM" "${IMAC[@]}" bash firmware.sh -v export_local "$OUT/imac-v"
check X6-imac-verbose-N2     'members_eq "$OUT/imac-v/firmware.tar" "$N2"'
run X7-imac-default-subcmd 0 "successfully saved"          "" "" "$MM" "${IMAC[@]}" HOME="$H" bash firmware.sh -i
check X8-imac-default-N2     'members_eq "$H/Downloads/apple-firmware-export/firmware.tar" "$N2"'
run X9-imac-no-ioreg     1 "Could not read this Mac's NVRAM and txcap file names" "" "" "$MM" "${IMAC_NOIOREG[@]}" bash firmware.sh export_local "$OUT/imac-noioreg"
check X10-no-ioreg-no-tar    '[ ! -e "$OUT/imac-noioreg/firmware.tar" ]'
run X11-imac-bad-ioreg   1 "has no such file"              "" "" "$MM" "${IMAC_BADIOREG[@]}" bash firmware.sh export_local "$OUT/imac-bad"
check X12-bad-ioreg-no-tar   '[ ! -e "$OUT/imac-bad/firmware.tar" ]'
run X13-imac-src-other-mac 1 "has no such file"            "" "" "$MM" "${IMAC[@]}" FIRMWARE_SRC="$F/rawtree-no4364b2" bash firmware.sh export_local "$OUT/imac-other"
check X14-src-other-mac-no-tar '[ ! -e "$OUT/imac-other/firmware.tar" ]'
# A failed export leaves an earlier firmware.tar in the output directory as it was.
mkdir -p "$OUT/imac-keep"; cp "$F/renamed-with-txcap.tar" "$OUT/imac-keep/firmware.tar"
run X15-imac-failed-export 1 "Could not read"              "" "" "$MM" "${IMAC_NOIOREG[@]}" bash firmware.sh export_local "$OUT/imac-keep"
check X16-earlier-tar-kept   'members_eq "$OUT/imac-keep/firmware.tar" "$N2"'
check X17-no-cwd-leftover    '[ ! -e "$REPO/$TXT" ] && [ ! -e "$REPO/$BLOB" ]'
run X18-imac-no-ioreg-i  1 "Could not read"                "" "" "$MM" "${IMAC_NOIOREG[@]}" HOME="$H" bash firmware.sh -i

echo "== macOS before Monterey (mocked sw_vers/system_profiler) =="
# The Bluetooth warning is for the three models that use the Bluetooth firmware, and only them.
run X19-bt-model-old-macos 0 "earlier than macOS Monterey" "" "" "$MM" "${BT_OLD_MACOS[@]}" bash firmware.sh export_local "$OUT/bt-old"
run X20-other-model-old-macos 0 "successfully saved"       "" "" "$MM" "${OTHER_OLD_MACOS[@]}" bash firmware.sh export_local "$OUT/other-old"
check X20-no-bluetooth-warning '! grep -q "earlier than macOS Monterey" "$OUT/X20-other-model-old-macos.out"'

echo "== Linux (mocked uname/sudo) =="
run L1-i-no-subcmd       1 "needs the path"                "-" "" "$ML" bash firmware.sh -i
run L2-prompted-path     0 "Firmware installation complete" "$B" "$B" "$ML" bash firmware.sh
run L3-emptydir          1 "no Wi-Fi firmware found"       "-" "" "$ML" bash firmware.sh -i install_local "$F/emptydir"
run L4-junkdir           1 "no Wi-Fi firmware found"       "-" "" "$ML" bash firmware.sh -i install_local "$F/junkdir"
run L5-dir               0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$SRC"
run L6-renamed-tar       0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$B"
run L7-raw-tar           0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$F/raw.tar"
run L8-raw-tar-gz        0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$F/raw.tar.gz"
run L9-raw-tar-txcap-root 0 "Firmware installation complete" "$BPAIR" "" "$ML" bash firmware.sh -i install_local "$F/raw-with-txcap-root.tar"
run L10-missing-path     1 "does not exist"                "-" "" "$ML" bash firmware.sh -i install_local "$F/nonexistent"
run L11-bad-format       1 "Unsupported file format"       "-" "" "$ML" bash firmware.sh -i install_local "$F/junkdir/readme.md"
run L12-legacy-tar-gz-txcap 0 "Firmware installation complete" "$BPAIR" "" "$ML" bash firmware.sh -i install_local "$F/legacy-txcap.tar.gz"
run L13-dir-txcap-root   0 "Firmware installation complete" "$BPAIR" "" "$ML" bash firmware.sh -i install_local "$F/rawtree-txcap"
run L14-dir-symlink-pair 0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$F/rawtree-symlink-txcap"
# A tar counts as renamed only if extracting it leaves a usable brcmfmac*.bin at the top level.
run L15-nested-bin-tar   1 "no Wi-Fi firmware found"       "-" "" "$ML" bash firmware.sh -i install_local "$F/nested-bin.tar"
run L16-empty-bin-tar    1 "no Wi-Fi firmware found"       "-" "" "$ML" bash firmware.sh -i install_local "$F/empty-bin.tar"
run L17-symlink-bin-tar  1 "no Wi-Fi firmware found"       "-" "" "$ML" bash firmware.sh -i install_local "$F/symlink-bin.tar"
run L18-renamed-dotslash-tar 0 "Firmware installation complete" "$F/renamed-dotslash.tar" "" "$ML" bash firmware.sh -i install_local "$F/renamed-dotslash.tar"
run L19-renamed-tar-gz   0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$F/renamed.tar.gz"
run L24-renamed-tgz      0 "Firmware installation complete" "$B" "" "$ML" bash firmware.sh -i install_local "$F/renamed.tgz"
# Only brcmfmac is reloaded on a model that does not use the Bluetooth firmware.
sudo_sequence L6-renamed-tar "mkdir -p /lib/firmware/brcm" "tar -xC /lib/firmware/brcm -f *" "modprobe -r brcmfmac_wcc" "modprobe -r brcmfmac" "modprobe brcmfmac"
# A driver that could not be reloaded is reported and fails the run. The files are
# installed by then, so the tar has run. Unloading brcmfmac_wcc may fail (older kernels lack it).
run L20-wifi-load-fails  1 "brcmfmac could not be"         "$B" "" "$ML" env SUDO_FAIL="modprobe brcmfmac" bash firmware.sh -i install_local "$B"
check L20-no-done            '! grep -q "Done!" "$OUT/L20-wifi-load-fails.out"'
check L20-modprobe-error-shown 'grep -q "FATAL: Module brcmfmac" "$OUT/L20-wifi-load-fails.out"'
run L21-wifi-unload-fails 1 "brcmfmac could not be"        "$B" "" "$ML" env SUDO_FAIL="modprobe -r brcmfmac" bash firmware.sh -i install_local "$B"
check L21-no-done            '! grep -q "Done!" "$OUT/L21-wifi-unload-fails.out"'
sudo_sequence L21-wifi-unload-fails "mkdir -p /lib/firmware/brcm" "tar -xC /lib/firmware/brcm -f *" "modprobe -r brcmfmac_wcc" "modprobe -r brcmfmac"
run L22-wcc-unload-fails 0 "Firmware installation complete" "$B" "" "$ML" env SUDO_FAIL="modprobe -r brcmfmac_wcc" bash firmware.sh -i install_local "$B"
# hci_bcm4377 is not touched on the other models, so its absence from the kernel cannot fail them.
run L23-bt-fails-other-model 0 "Firmware installation complete" "$B" "" "$ML" env SUDO_FAIL="modprobe hci_bcm4377" bash firmware.sh -i install_local "$B"
check L23-no-bt-reload       '! grep -q hci_bcm4377 "$OUT/L23-bt-fails-other-model.sudo"'

echo "== Linux on MacBookPro16,3 (mocked DMI read) =="
run B1-bt-model-installs 0 "Firmware installation complete" "$B" "" "$ML" "${LINUX_BT[@]}" bash firmware.sh -i install_local "$B"
sudo_sequence B1-bt-model-installs "mkdir -p /lib/firmware/brcm" "tar -xC /lib/firmware/brcm -f *" "modprobe -r brcmfmac_wcc" "modprobe -r brcmfmac" "modprobe brcmfmac" "modprobe -r hci_bcm4377" "modprobe hci_bcm4377"
run B2-bt-load-fails     1 "hci_bcm4377 could not be"      "$B" "" "$ML" "${LINUX_BT[@]}" SUDO_FAIL="modprobe hci_bcm4377" bash firmware.sh -i install_local "$B"
check B2-no-done             '! grep -q "Done!" "$OUT/B2-bt-load-fails.out"'
check B2-wifi-still-reloaded 'grep -qx "sudo: modprobe brcmfmac" "$OUT/B2-bt-load-fails.sudo"'
run B3-bt-unload-fails   1 "hci_bcm4377 could not be"      "$B" "" "$ML" "${LINUX_BT[@]}" SUDO_FAIL="modprobe -r hci_bcm4377" bash firmware.sh -i install_local "$B"

echo "== Linux on iMac19,1 (mocked DMI read) =="
run I1-dir-no-txcap      1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$SRC"
check I1-linux-hint          'grep -q export_local "$OUT/I1-dir-no-txcap.out"'
run I2-renamed-no-txcap  1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$B"
run I3-renamed-with-txcap 0 "Firmware installation complete" "$BPAIR" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-with-txcap.tar"
run I4-legacy-tar-gz-txcap  0 "Firmware installation complete" "$BPAIR" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/legacy-txcap.tar.gz"
run I5-raw-tar-txcap-root 0 "Firmware installation complete" "$BPAIR" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/raw-with-txcap-root.tar"
run I6-dir-txcap-root    0 "Firmware installation complete" "$BPAIR" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/rawtree-txcap"
run I7-renamed-blob-only 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-blob-only.tar"
run I8-renamed-txt-only  1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-txt-only.tar"
run I9-renamed-nested-txcap 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-nested-txcap.tar"
run I10-raw-tar-gz-no-txcap 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/raw.tar.gz"
# The fake iMac19,1's own export (X1) installs on the fake iMac19,1.
run I11-mac-export-installs 0 "Firmware installation complete" "$OUT/imac-ok/firmware.tar" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$OUT/imac-ok/firmware.tar"
run I12-renamed-symlink-txcap 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-symlink-txcap.tar"
run I13-renamed-empty-txcap 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/renamed-empty-txcap.tar"
run I14-dir-symlink-pair 1 "iMac19,1 needs brcmfmac4364b2-pcie.txt" "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/rawtree-symlink-txcap"
# Refused by the renamer, not the txcap guard: the archive was never accepted as renamed.
run I15-nested-bin-tar   1 "no Wi-Fi firmware found"       "-" "" "$ML" "${LINUX_IMAC[@]}" bash firmware.sh -i install_local "$F/nested-bin.tar"

echo "== $pass passed, $fail failed =="
[ "$fail" = 0 ]
