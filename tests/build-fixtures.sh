#!/usr/bin/env bash
# Builds the inputs run.sh feeds firmware.sh into the directory given as $1, from this
# Mac's /usr/share/firmware. The tree is Apple's, so nothing here is checked in; every
# fixture is derived at run time.
#
# renamed.tar is rename_firmware.py's own output on the tree and stands in for a
# firmware.tar from export_local on a Mac that is not one of the txcap models. The
# renamed-*.tar fixtures are built from it, the raw* ones from the tree itself.
set -euo pipefail

F=$1
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SRC=/usr/share/firmware
SRC4364="$SRC/wifi/C-4364__s-B2"
TXT=brcmfmac4364b2-pcie.txt
BLOB=brcmfmac4364b2-pcie.txcap_blob

[ -d "$SRC/wifi" ] || { echo "build-fixtures: $SRC/wifi not found; this needs a Mac" >&2; exit 2; }
# The fake iMac19,1 cases need a 4364b2 pair ioreg could name: kauai-X3.txcb and a
# P-kauai-X3*.txt, which is what a real iMac19,1 requests.
KAUAI_TXT=$(cd "$SRC4364" 2>/dev/null && printf '%s\n' P-kauai-X3*.txt | head -1)
if ! [ -f "$SRC4364/$KAUAI_TXT" ] || ! [ -f "$SRC4364/kauai-X3.txcb" ]; then
	echo "build-fixtures: $SRC4364 lacks kauai-X3.txcb or a P-kauai-X3*.txt" >&2; exit 2
fi

# A copy of the tree's wifi/ and bluetooth/ (the latter only from Monterey on).
copy_tree() {
	mkdir -p "$1"
	cp -R "$SRC/wifi" "$1/"
	if [ -d "$SRC/bluetooth" ]; then cp -R "$SRC/bluetooth" "$1/"; fi
}

mkdir "$F"
mkdir "$F/emptydir" "$F/junkdir"
echo "$KAUAI_TXT" > "$F/kauai-txt-name"
echo junk > "$F/junkdir/readme.md"

B="$F/renamed.tar"
python3 "$REPO/rename_firmware.py" "$SRC" "$B"

# Raw tree archives as the upstream script's copy_to_efi builds them (tree under ./).
tar -cf "$F/raw.tar" -C "$SRC" .
gzip -c --best "$F/raw.tar" > "$F/raw.tar.gz"

# A tree with a synthesized pair at its root, as the upstream script's EFI step leaves
# it (6-byte files; the content is never read).
copy_tree "$F/rawtree-txcap"
printf 'nvram\n' > "$F/rawtree-txcap/$TXT"
printf 'txcap\n' > "$F/rawtree-txcap/$BLOB"
cp "$F/raw.tar" "$F/raw-with-txcap-root.tar"
(cd "$F/rawtree-txcap" && tar --append -f "$F/raw-with-txcap-root.tar" "$TXT" "$BLOB")
# The legacy firmware-raw.tar.gz: raw tree plus the pair, gzipped.
gunzip -c "$F/raw.tar.gz" > "$F/legacy-txcap.tar"
(cd "$F/rawtree-txcap" && tar --append -f "$F/legacy-txcap.tar" "$TXT" "$BLOB")
gzip --best "$F/legacy-txcap.tar"

# Renamed archives with the pair complete, half of it, or nested.
cp "$B" "$F/renamed-with-txcap.tar"
(cd "$F/rawtree-txcap" && tar --append -f "$F/renamed-with-txcap.tar" "$TXT" "$BLOB")
cp "$B" "$F/renamed-blob-only.tar"
(cd "$F/rawtree-txcap" && tar --append -f "$F/renamed-blob-only.tar" "$BLOB")
cp "$B" "$F/renamed-txt-only.tar"
(cd "$F/rawtree-txcap" && tar --append -f "$F/renamed-txt-only.tar" "$TXT")
mkdir -p "$F/nested/sub"
cp "$F/rawtree-txcap"/brcmfmac4364b2-pcie.* "$F/nested/sub/"
cp "$B" "$F/renamed-nested-txcap.tar"
tar --append -f "$F/renamed-nested-txcap.tar" -C "$F/nested" "sub/$TXT" "sub/$BLOB"

# A tree from "another Mac" with no 4364b2 directory at all.
copy_tree "$F/rawtree-no4364b2"
rm -rf "$F/rawtree-no4364b2/wifi/C-4364__s-B2"

# The pair present under the right names but not as usable files: dangling symlinks
# appended to a renamed tar, zero-byte files, and a tree whose root pair are relative
# symlinks that resolve in place but not once extracted into /lib/firmware/brcm.
mkdir -p "$F/dangling"
ln -s nonexistent-nvram "$F/dangling/$TXT"
ln -s nonexistent-blob "$F/dangling/$BLOB"
cp "$B" "$F/renamed-symlink-txcap.tar"
(cd "$F/dangling" && tar --append -f "$F/renamed-symlink-txcap.tar" "$TXT" "$BLOB")
mkdir -p "$F/empty-pair"
: > "$F/empty-pair/$TXT"
: > "$F/empty-pair/$BLOB"
cp "$B" "$F/renamed-empty-txcap.tar"
(cd "$F/empty-pair" && tar --append -f "$F/renamed-empty-txcap.tar" "$TXT" "$BLOB")
copy_tree "$F/rawtree-symlink-txcap"
ln -s "wifi/C-4364__s-B2/$KAUAI_TXT" "$F/rawtree-symlink-txcap/$TXT"
ln -s wifi/C-4364__s-B2/kauai-X3.txcb "$F/rawtree-symlink-txcap/$BLOB"

# A .tar counts as renamed only if extracting it leaves a usable brcmfmac*.bin at the
# top level: the only member nested, the name as a zero-byte file, the name as a
# dangling symlink, the renamed archive re-stored under ./, and the renamed archive
# gzipped under each suffix install_local accepts for it.
mkdir -p "$F/nested-bin/wrong-subdir"
echo data > "$F/nested-bin/wrong-subdir/brcmfmac4364b3-pcie.apple.bin"
tar -cf "$F/nested-bin.tar" -C "$F/nested-bin" wrong-subdir/brcmfmac4364b3-pcie.apple.bin
mkdir -p "$F/empty-bin"
: > "$F/empty-bin/brcmfmac4364b3-pcie.apple.bin"
tar -cf "$F/empty-bin.tar" -C "$F/empty-bin" brcmfmac4364b3-pcie.apple.bin
mkdir -p "$F/symlink-bin"
ln -s nonexistent.bin "$F/symlink-bin/brcmfmac4364b3-pcie.apple.bin"
tar -cf "$F/symlink-bin.tar" -C "$F/symlink-bin" brcmfmac4364b3-pcie.apple.bin
mkdir -p "$F/renamed-tree"
tar -xf "$B" -C "$F/renamed-tree"
(cd "$F/renamed-tree" && tar -cf "$F/renamed-dotslash.tar" ./*)
gzip -c --best "$B" > "$F/renamed.tar.gz"
cp "$F/renamed.tar.gz" "$F/renamed.tgz"
