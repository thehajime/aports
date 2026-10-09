#!/bin/sh
# Prepare the kernel UAPI and verify the compiler/plugin/sysroot used by the
# opt-in SWMMU package profile. Run this in the same toolchain container used
# for abuild.
set -eu

usage() {
	cat >&2 <<'EOF'
Usage: swmmu-prepare.sh headers|check

Required environment:
  SWMMU_KERNEL_SRC   Linux source tree
  SWMMU_KERNEL_BUILD configured Linux output tree
  SWMMU_UAPI         UAPI include directory (headers are installed in its parent)
  SWMMU_SYSROOT      instrumented musl sysroot directory
  SWMMU_PLUGIN       swmmu_plugin.so built for SWMMU_GCC
  SWMMU_GCC          guest GCC executable (same plugin ABI as plugin build)

The headers command installs exported kernel headers. The check command
validates inputs and asks GCC to load the plugin before any package build.
EOF
	exit 2
}

[ "$#" -eq 1 ] || usage
action=$1
: "${SWMMU_KERNEL_SRC:?Set SWMMU_KERNEL_SRC to the Linux source tree}"
: "${SWMMU_KERNEL_BUILD:?Set SWMMU_KERNEL_BUILD to the configured Linux output tree}"
: "${SWMMU_UAPI:?Set SWMMU_UAPI to the exported UAPI include directory}"
: "${SWMMU_PLUGIN:?Set SWMMU_PLUGIN to swmmu_plugin.so}"
SWMMU_GCC=${SWMMU_GCC:-gcc}

case "$action" in
headers)
	case "$SWMMU_UAPI" in
	*/include) install_hdr_path=${SWMMU_UAPI%/include} ;;
	*) echo "SWMMU_UAPI must end in /include" >&2; exit 2 ;;
	esac
	mkdir -p "$install_hdr_path"
	make -C "$SWMMU_KERNEL_SRC" O="$SWMMU_KERNEL_BUILD" ARCH=um \
		INSTALL_HDR_PATH="$install_hdr_path" headers_install
	exit 0
	;;
check)
	: "${SWMMU_SYSROOT:?Set SWMMU_SYSROOT to the instrumented musl sysroot directory}"
	;;
*) usage ;;
esac

for path in "$SWMMU_KERNEL_SRC" "$SWMMU_KERNEL_BUILD" "$SWMMU_UAPI" "$SWMMU_SYSROOT"; do
	[ -d "$path" ] || { echo "Missing directory: $path" >&2; exit 1; }
done
[ -r "$SWMMU_UAPI/linux/nommu_swmmu.h" ] || {
	echo "Missing SWMMU kernel header: $SWMMU_UAPI/linux/nommu_swmmu.h" >&2; exit 1;
}
[ -r "$SWMMU_PLUGIN" ] || { echo "Missing plugin: $SWMMU_PLUGIN" >&2; exit 1; }

for file in include/stdio.h include/swmmu_plugin_runtime.h include/swmmu_runtime.h \
	lib/Scrt1.o lib/crt1.o lib/crti.o lib/crtn.o lib/libc.a lib/libssp_nonshared.a; do
	[ -r "$SWMMU_SYSROOT/usr/$file" ] || {
		echo "Missing instrumented sysroot file: $SWMMU_SYSROOT/usr/$file" >&2; exit 1;
	}
done
[ -L "$SWMMU_SYSROOT/lib/ld-musl-x86_64.so.1" ] && \
	[ "$(readlink "$SWMMU_SYSROOT/lib/ld-musl-x86_64.so.1")" = /usr/lib/libc.so ] && \
	[ -r "$SWMMU_SYSROOT/usr/lib/libc.so" ] || {
	echo "Missing instrumented musl interpreter in $SWMMU_SYSROOT" >&2; exit 1;
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM
printf 'int swmmu_plugin_probe(void) { return 0; }\n' > "$tmpdir/probe.c"
"$SWMMU_GCC" -nostdinc -isystem "$SWMMU_SYSROOT/usr/include" \
	-isystem "$SWMMU_UAPI" \
	-include "$SWMMU_SYSROOT/usr/include/swmmu_plugin_runtime.h" \
	-DSWMMU_ALL_ACCESS=1 -fplugin="$SWMMU_PLUGIN" \
	-fplugin-arg-swmmu_plugin-all-access=1 -c "$tmpdir/probe.c" \
	-o "$tmpdir/probe.o" || {
	echo "GCC could not load SWMMU_PLUGIN; use the GCC version the plugin was built for" >&2
	exit 1
}

echo "SWMMU toolchain ready: $($SWMMU_GCC -dumpfullversion), $SWMMU_PLUGIN"
