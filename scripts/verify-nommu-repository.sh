#!/bin/sh
# Verify a complete release repository using only its own trusted key and files.
set -eu
root=$(realpath "${1:?usage: verify-nommu-repository.sh PROFILE_DIRECTORY}")
test -s "$root/manifest.json"
test -s "$root/x86_64/APKINDEX.tar.gz"
(cd "$root" && sha256sum -c SHA256SUMS)
python3 - "$root" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "manifest.json").read_text())
actual = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
          for p in (root / "x86_64").glob("*.apk")}
expected = {p["file"]: p["sha256"] for p in manifest["packages"]}
assert actual and actual == expected, "manifest/package set or SHA-256 mismatch"
assert len(expected) == len(manifest["packages"]), "duplicate manifest package"
assert manifest["index_sha256"] == hashlib.sha256(
    (root / "x86_64/APKINDEX.tar.gz").read_bytes()).hexdigest(), "index hash mismatch"
PY
for package in "$root"/x86_64/*.apk; do
	apk --no-network --repositories-file /dev/null --keys-dir "$root/keys" verify "$package"
done
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
apk --root "$scratch" --no-network --keys-dir "$root/keys" \
	--repositories-file /dev/null add --initdb
apk --root "$scratch" --no-network --keys-dir "$root/keys" \
	--repositories-file /dev/null --repository "$root" update
profile=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["profile"])' "$root/manifest.json")
if [ "$profile" = nommu-plain ]; then
	set -- "$root"/x86_64/*.apk
	[ "$#" -eq 2 ] || { echo 'plain must contain exactly musl and BusyBox' >&2; exit 1; }
	apk --root "$scratch" --no-network --keys-dir "$root/keys" \
		--repositories-file /dev/null --repository "$root" add --simulate musl-nommu busybox-nommu
	exit
fi
[ "$profile" = nommu-svm ] || exit 1
apk --root "$scratch" --no-network --keys-dir "$root/keys" \
	--repositories-file /dev/null --repository "$root" \
	add --simulate musl-nommu busybox-nommu openssl zlib-nommu ncurses-nommu \
	pcre-nommu libcap-nommu ca-certificates-bundle apk-tools-nommu \
	python3-nommu nginx-nommu coreutils-nommu iperf3-nommu gmp zsh emacs \
	libevent-nommu sqlite-nommu memcached-nommu
apk --root "$scratch" --no-network --keys-dir "$root/keys" \
	--repositories-file /dev/null --repository "$root" \
	add --simulate "$root"/x86_64/*.apk
