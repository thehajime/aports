#!/bin/sh
set -eu
script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
trap 'status=$?; if [ "$status" -ne 0 ]; then echo "build-nommu-apks.sh failed (exit $status)" >&2; fi' EXIT

apk add --no-cache alpine-sdk bash doas git curl ca-certificates bc bison flex openssl-dev perl python3 elfutils-dev gmp-dev mpfr-dev mpc1-dev isl-dev rsync \
	autoconf automake libtool diffutils ncurses ncurses-dev pcre-dev libcap-dev gawk texinfo meson lua5.4
install -m755 /src/main/meson/abuild-meson /usr/local/bin/abuild-meson
ln -sf /usr/bin/lua5.4 /usr/local/bin/lua5.5

# Build the SVM plugin with the same Alpine GCC used for the guest packages.
# GCC plugins are tied to the host compiler ABI.
make -C /kernel ARCH=um O=/tmp/kernel-build x86_64_defconfig
/kernel/scripts/config --file /tmp/kernel-build/.config \
	--disable MMU --disable SMP --disable PREEMPTION \
	--enable UML_NOMMU_SAS \
	--enable SVM_PAGETABLE \
	--enable UML_SVM_TABLE \
	--enable GCC_PLUGINS \
	--enable GCC_PLUGIN_SVM
make -C /kernel ARCH=um O=/tmp/kernel-build olddefconfig
grep -q '^CONFIG_GCC_PLUGIN_SVM=y$' /tmp/kernel-build/.config
grep -q '^CONFIG_UML_SVM_TABLE=y$' /tmp/kernel-build/.config
make -C /kernel ARCH=um O=/tmp/kernel-build scripts
make -C /kernel ARCH=um O=/tmp/kernel-build \
	INSTALL_HDR_PATH=/tmp/kernel-uapi headers_install
test -r /tmp/kernel-build/scripts/gcc-plugins/svm_plugin.so
test -r /tmp/kernel-uapi/include/linux/svm_prctl.h

addgroup -S abuild 2>/dev/null || true
adduser -D -G abuild builder
mkdir -p /etc/doas.d /var/cache/distfiles /out/keys
printf 'permit nopass builder as root\n' >/etc/doas.d/abuild.conf
chmod 0400 /etc/doas.d/abuild.conf

for profile in nommu-plain nommu-svm; do
	mkdir -p "/home/builder/aports-$profile/main" "/home/builder/aports-$profile/scripts" "/out/$profile/packages" "/out/$profile/tools" "/out/$profile/toolchain"
	cp -a /src/main/musl /src/main/busybox "/home/builder/aports-$profile/main/"
	cp -a /src/scripts/svm-profile.sh "/home/builder/aports-$profile/scripts/"
	if [ "$profile" = nommu-svm ]; then
		cp -a /src/main/zlib /src/main/ncurses /src/main/pcre /src/main/libcap \
			/src/main/openssl /src/main/apk-tools /src/main/python3 /src/main/nginx \
			/src/main/coreutils /src/main/iperf3 \
			"/home/builder/aports-$profile/main/"
	fi
done
chown -R builder:abuild /home/builder /out /var/cache/distfiles

su -s /bin/sh builder -c '
set -eu
export PACKAGER="UML CI <uml-ci@example.invalid>"
abuild-keygen -a -n
doas cp "$HOME"/.abuild/*.rsa.pub /etc/apk/keys/

abuild_fetch_retry() {
	attempt=1
	while ! abuild fetch; do
		if [ "$attempt" -ge 5 ]; then
			echo "source fetch failed after $attempt attempts in $PWD" >&2
			return 1
		fi
		delay=$((attempt * 10))
		echo "source fetch attempt $attempt failed; retrying in ${delay}s" >&2
		sleep "$delay"
		attempt=$((attempt + 1))
	done
}

build_profile() {
	profile=$1
	export REPODEST="/out/$profile"
	${CC:-gcc} -dumpfullversion >"/out/$profile/toolchain/gcc-version"
	if [ "$profile" = nommu-svm ]; then
		export SVM=1
		export SVM_PLUGIN=/tmp/kernel-build/scripts/gcc-plugins/svm_plugin.so
		export SVM_UAPI=/tmp/kernel-uapi/include
		export SVM_SYSROOT="$HOME/svm-sysroot"
		export CFLAGS="${CFLAGS:-} -fno-lto" CXXFLAGS="${CXXFLAGS:-} -fno-lto"
	else
		export SVM=0
		unset SVM_PLUGIN SVM_UAPI SVM_SYSROOT
	fi
	cd "$HOME/aports-$profile/main/musl"
	abuild_fetch_retry
	abuild -r
	cd "$HOME/aports-$profile/main/busybox"
	abuild_fetch_retry
	abuild -r
	if [ "$profile" = nommu-svm ]; then
		for package in openssl zlib ncurses pcre libcap; do
			cd "$HOME/aports-$profile/main/$package"
			abuild_fetch_retry
			SVM_ONLY=1 abuild -d -r
		done
		for package in apk-tools python3 nginx coreutils iperf3; do
			cd "$HOME/aports-$profile/main/$package"
			abuild_fetch_retry
			SVM_ONLY=1 abuild -d -r
		done
	fi
	for package in busybox-nommu musl-nommu; do
		set -- "$REPODEST/main/x86_64/$package"-*.apk
		[ "$#" -eq 1 ] && [ -f "$1" ] || {
			echo "expected one built APK for $profile/$package; matches: $*" >&2
			exit 1
		}
		echo "Collecting $profile/$package: $1"
		cp "$1" "/out/$profile/packages/"
	done
	if [ "$profile" = nommu-svm ]; then
		for package in zlib-nommu ncurses-nommu pcre-nommu libcap-nommu apk-tools-nommu python3-nommu nginx-nommu coreutils-nommu iperf3-nommu; do
			set -- "$REPODEST/main/x86_64/$package"-[0-9]*.apk
			[ "$#" -eq 1 ] && [ -f "$1" ] || {
				echo "expected one built SVM APK for $package; matches: $*" >&2
				exit 1
			}
			echo "Collecting $profile/$package: $1"
			cp "$1" "/out/$profile/packages/"
		done
		for package_glob in openssl-[0-9]* libcrypto3-[0-9]* libssl3-[0-9]*; do
			set -- $REPODEST/main/x86_64/$package_glob.apk
			for apk in "$@"; do
				[ -f "$apk" ] && cp "$apk" "/out/$profile/packages/"
			done
		done
	fi
	set -- "$REPODEST/main/x86_64/busybox-static"-*.apk
	[ "$#" -eq 1 ] && [ -f "$1" ] || {
		echo "expected one static host BusyBox APK for $profile; matches: $*" >&2
		exit 1
	}
	echo "Extracting host BusyBox from: $1"
	if ! tar -xOf "$1" bin/busybox.static >"/out/$profile/tools/busybox-host"; then
		echo "could not extract bin/busybox.static from $1; APK entries follow:" >&2
		tar -tvf "$1" >&2 || true
		exit 1
	fi
	chmod 755 "/out/$profile/tools/busybox-host"
}

build_profile nommu-plain
build_profile nommu-svm

set -- "$HOME/.abuild/"*.rsa.pub
[ "$#" -eq 1 ] && [ -f "$1" ] || {
	echo "expected one abuild public key; matches: $*" >&2
	ls -la "$HOME/.config/abuild" >&2 || true
	exit 1
}
echo "Collecting abuild public key: $1"
cp "$1" /out/keys/
'
