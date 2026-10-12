#!/usr/bin/env python3
# Prints what extracting the tar archive given as $1 would leave, one member per line,
# sorted: the member name, then the SHA-256 of a file's contents (a hard link gets its
# target's, since that is what lands under its name), "symlink <target>", or the member
# type. Two archives with the same manifest install the same names with the same
# contents, whatever their member order, compression or header fields (mtime, owner,
# mode), so run.sh compares archives by it.
import hashlib, sys, tarfile

def describe(archive, member):
	if member.isfile() or member.islnk():
		return hashlib.sha256(archive.extractfile(member).read()).hexdigest()
	if member.issym():
		return f"symlink {member.linkname}"
	return "dir" if member.isdir() else f"type {member.type.decode()}"

with tarfile.open(sys.argv[1]) as archive:
	for line in sorted(f"{m.name} {describe(archive, m)}" for m in archive):
		print(line)
