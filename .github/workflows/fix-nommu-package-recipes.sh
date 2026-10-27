#!/bin/sh
# Checked compatibility edits in a disposable aports package tree.
set -eu
[ "$#" -eq 1 ] || { echo "Usage: $0 MAIN_PACKAGE_DIRECTORY" >&2; exit 2; }
scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
main=$1

target="$main/apk-tools/APKBUILD"
temporary=$(mktemp "${target}.XXXXXX")
cp "$target" "$temporary"
BEFORE='source="https://gitlab.alpinelinux.org/alpine/apk-tools/-/archive/v$pkgver/apk-tools-v$pkgver.tar.gz' \
AFTER='source="apk-tools-v$pkgver.tar.gz::https://github.com/alpinelinux/apk-tools/archive/refs/tags/v$pkgver.tar.gz' \
    sh "$scripts/replace-literal.sh" "$temporary"
BEFORE='builddir="$srcdir/apk-tools-v$pkgver"' \
AFTER='builddir="$srcdir/apk-tools-$pkgver"' \
    sh "$scripts/replace-literal.sh" "$temporary"
BEFORE='3616435508dead5240f8d9fe74e87e2aa93262f9e466f50af8f60100e166403393b1e491c115395864d4179b219699831ecb61dc60960b5dfb1f10816d75f95f  apk-tools-v3.0.8.tar.gz' \
AFTER='3149277dd14c0f4a0698bf7a0eb4e09a264105f24f9bcd7f6a7b2262e3a2d142402cbc0bade83f5ea23ef2a414c4393abfa63260c0659f70978425bc036ea6ed  apk-tools-v3.0.8.tar.gz' \
    sh "$scripts/replace-literal.sh" "$temporary"
cat "$temporary" > "$target"
rm -f "$temporary"

target="$main/python3/APKBUILD"
temporary=$(mktemp "${target}.XXXXXX")
cp "$target" "$temporary"
BEFORE='	makedepends="bash python3-dev openssl-dev"' \
AFTER='	makedepends="$makedepends bash python3-dev openssl-dev"' \
    sh "$scripts/replace-literal.sh" "$temporary"
BEFORE='	arch="x86_64"
	subpackages="$pkgname-nommu::x86_64"' \
AFTER='	arch="x86_64"
	subpackages="$pkgname-nommu::x86_64"
	options="$options !tracedeps"' \
    sh "$scripts/replace-literal.sh" "$temporary"
BEFORE='		ac_cv_file__dev_ptmx=yes \
' \
AFTER='		PKG_CONFIG=false \
		ac_cv_file__dev_ptmx=yes \
' \
    sh "$scripts/replace-literal.sh" "$temporary"
cat "$temporary" > "$target"
rm -f "$temporary"
