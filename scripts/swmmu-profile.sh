# shellcheck shell=sh disable=SC2034,SC2154,SC3043
# Shared, opt-in x86_64 SWMMU build profile, sourced by APKBUILDs.
# Guest instrumentation must never leak into HOSTCC/HOSTCXX.

swmmu_require() {
	[ "${SWMMU:-0}" = 1 ] || { error "Set SWMMU=1 to request SWMMU binaries"; return 1; }
	[ "$CARCH" = x86_64 ] || { error "SWMMU requires x86_64"; return 1; }
	local path
	for path in "${SWMMU_PLUGIN:-}" "${SWMMU_UAPI:-}"; do
		case "$path" in
		/*) ;;
		*) error "SWMMU_PLUGIN and SWMMU_UAPI must be absolute paths"; return 1;;
		esac
		case "$path" in
		*[[:space:]]*) error "SWMMU paths must not contain whitespace"; return 1;;
		esac
	done
	[ "${SWMMU_PLUGIN##*/}" = swmmu_plugin.so ] && [ -r "$SWMMU_PLUGIN" ] || {
		error "Missing swmmu_plugin.so for the guest compiler"; return 1;
	}
	[ -r "$SWMMU_UAPI/linux/nommu_swmmu.h" ] && [ -r "$SWMMU_UAPI/asm/unistd.h" ] || {
		error "SWMMU_UAPI must contain exported kernel headers"; return 1;
	}
}

swmmu_musl_flags() {
	swmmu_require || return 1
	[ -r "$builddir/src/include/swmmu_plugin_runtime.h" ] || {
		error "The supplied musl runtime patch has not been applied"; return 1;
	}
	SWMMU_CFLAGS="-DDL_NOMMU_SUPPORT=1 -DSWMMU_ALL_ACCESS=1 -fplugin=$SWMMU_PLUGIN -fplugin-arg-swmmu_plugin-all-access=1"
	SWMMU_RUNTIME_CFLAGS="-include $builddir/src/include/swmmu_plugin_runtime.h"
	SWMMU_CPPFLAGS="-idirafter $SWMMU_UAPI"
	case "${SWMMU_DIRECT_WINDOW:-0}" in
	0) ;;
	1)
		[ -r "$builddir/src/include/swmmu_direct_window_guard.h" ] || {
			error "Missing direct-window runtime header"; return 1;
		}
		SWMMU_CFLAGS="$SWMMU_CFLAGS -DSWMMU_BUILDING_LIBC=1 -fplugin-arg-swmmu_plugin-direct-window=1"
		SWMMU_RUNTIME_CFLAGS="$SWMMU_RUNTIME_CFLAGS -include $builddir/src/include/swmmu_direct_window_guard.h"
		;;
	*) error "SWMMU_DIRECT_WINDOW must be 0 or 1"; return 1;;
	esac
}

swmmu_guest_profile() {
	swmmu_require || return 1
	case "$SWMMU_SYSROOT" in
	/*) ;;
	*) error "SWMMU_SYSROOT must be an absolute staging directory"; return 1;;
	esac
	case "$SWMMU_SYSROOT" in
	*[[:space:]]*) error "SWMMU_SYSROOT must not contain whitespace"; return 1;;
	esac
	local name
	for name in include/stdio.h include/swmmu_plugin_runtime.h include/swmmu_runtime.h \
		lib/Scrt1.o lib/crt1.o lib/rcrt1.o lib/crti.o lib/crtn.o lib/libc.a lib/libssp_nonshared.a; do
		[ -r "$SWMMU_SYSROOT/usr/$name" ] || {
			error "Missing instrumented sysroot file: usr/$name"; return 1;
		}
	done
	[ -L "$SWMMU_SYSROOT/lib/ld-musl-x86_64.so.1" ] && \
		[ "$(readlink "$SWMMU_SYSROOT/lib/ld-musl-x86_64.so.1")" = /usr/lib/libc.so ] && \
		[ -r "$SWMMU_SYSROOT/usr/lib/libc.so" ] || {
		error "Missing instrumented musl interpreter in SWMMU_SYSROOT"; return 1;
	}
	local wrapper_source="${SWMMU_WRAPPER_SOURCE:-$startdir/../../scripts/swmmu-cc}"
	[ -r "$wrapper_source" ] || { error "Missing SWMMU compiler wrapper: $wrapper_source"; return 1; }
	# musl's GCC specs select staged headers and crt objects, not just -L.
	# Preserve the compiler's original cc1/link switches and Alpine hardening.
	cat > "$srcdir/swmmu.specs" <<-EOF
	%rename cpp_options swmmu_cpp_options
	%rename cc1 swmmu_cc1
	%rename link swmmu_link

	*cpp_options:
	-nostdinc -isystem $SWMMU_SYSROOT/usr/include -isystem $SWMMU_UAPI -isystem include%s %(swmmu_cpp_options)

	*cc1:
	%(swmmu_cc1) -nostdinc -isystem $SWMMU_SYSROOT/usr/include -isystem $SWMMU_UAPI -isystem include%s

	*link_libgcc:
	-L$SWMMU_SYSROOT/usr/lib -L .%s

	*libgcc:
	libgcc.a%s %:if-exists(libgcc_eh.a%s)

	*startfile:
	%{!shared:%{static-pie:$SWMMU_SYSROOT/usr/lib/rcrt1.o;static:$SWMMU_SYSROOT/usr/lib/crt1.o;:$SWMMU_SYSROOT/usr/lib/Scrt1.o}} $SWMMU_SYSROOT/usr/lib/crti.o %{static:crtbeginT.o%s;:crtbeginS.o%s}

	*endfile:
	%{static:crtend.o%s;:crtendS.o%s} $SWMMU_SYSROOT/usr/lib/crtn.o

	*link:
	%(swmmu_link) -nostdlib %{!static:%{!static-pie:-dynamic-linker /lib/ld-musl-x86_64.so.1}}

	EOF
	local real_cc="${CC:-${CROSS_COMPILE}gcc}"
	case "$real_cc" in
	/*) ;;
	*) real_cc=$(command -v "$real_cc") || { error "Guest GCC not found: $real_cc"; return 1; };;
	esac
	export SWMMU_REAL_CC="$real_cc"
	export SWMMU_SPECS="$srcdir/swmmu.specs" SWMMU_PLUGIN SWMMU_UAPI SWMMU_SYSROOT
	export SWMMU_RUNTIME_HEADER="${SWMMU_RUNTIME_HEADER:-$SWMMU_SYSROOT/usr/include/swmmu_plugin_runtime.h}"
	export SWMMU_DIRECT_WINDOW="${SWMMU_DIRECT_WINDOW:-0}"
	case "$SWMMU_DIRECT_WINDOW" in
	0) ;;
	1) [ -r "$SWMMU_SYSROOT/usr/include/swmmu_direct_window_guard.h" ] || {
		error "Missing direct-window sysroot header"; return 1;
	};;
	*) error "SWMMU_DIRECT_WINDOW must be 0 or 1"; return 1;;
	esac
	install -m755 "$wrapper_source" "$srcdir/swmmu-cc"
	export CC="$srcdir/swmmu-cc"
}

swmmu_stage_musl() {
	case "$SWMMU_SYSROOT" in
	/*) ;;
	*) error "SWMMU_SYSROOT is required to retain development files"; return 1;;
	esac
	make DESTDIR="$SWMMU_SYSROOT" install || return 1
	install -Dm644 "$builddir/src/include/swmmu_runtime.h" \
		"$SWMMU_SYSROOT/usr/include/swmmu_runtime.h" || return 1
	install -Dm644 "$builddir/src/include/swmmu_plugin_runtime.h" \
		"$SWMMU_SYSROOT/usr/include/swmmu_plugin_runtime.h" || return 1
	install -Dm644 "$builddir/src/include/swmmu_direct_window_guard.h" \
		"$SWMMU_SYSROOT/usr/include/swmmu_direct_window_guard.h" || return 1
	# libc.so is a relative link to /lib in musl's install layout.
	# Retain libssp_nonshared for Alpine's normal linker flags as well.
	install -m644 "$builddir/libssp_nonshared.a" "$SWMMU_SYSROOT/usr/lib/"
}
