# shellcheck shell=sh disable=SC2034,SC2154,SC3043
# Shared, opt-in x86_64 SVM build profile, sourced by APKBUILDs.
# Guest instrumentation must never leak into HOSTCC/HOSTCXX.

svm_require() {
	[ "${SVM:-0}" = 1 ] || {
		error "Set SVM=1 to request SVM binaries"
		return 1
	}
	[ "${SWMMU:-0}" != 1 ] || {
		error "Select one SVM or SWMMU profile"
		return 1
	}
	[ "$CARCH" = x86_64 ] || {
		error "SVM currently requires UML x86_64"
		return 1
	}
	local path
	for path in "${SVM_PLUGIN:-}" "${SVM_SYSROOT:-}"; do
		case "$path" in
		/*) ;;
		*) error "SVM_PLUGIN and SVM_SYSROOT must be absolute paths"; return 1 ;;
		esac
		case "$path" in
		*[[:space:]]*) error "SVM paths must not contain whitespace"; return 1 ;;
		esac
	done
	[ -r "$SVM_PLUGIN" ] || {
		error "Missing SVM GCC plugin: $SVM_PLUGIN"
		return 1
	}
	[ -x "$SVM_SYSROOT/usr/bin/svm-gcc" ] || {
		error "Missing staged SVM compiler: $SVM_SYSROOT/usr/bin/svm-gcc"
		return 1
	}
	for path in include/stdio.h lib/Scrt1.o lib/rcrt1.o lib/crti.o lib/crtn.o \
		lib/libc.a lib/libssp_nonshared.a lib/svm-note.o lib/svm-gcc.specs; do
		[ -r "$SVM_SYSROOT/usr/$path" ] || {
			error "Missing staged SVM sysroot file: usr/$path"
			return 1
		}
	done
	[ -L "$SVM_SYSROOT/lib/ld-musl-x86_64.so.1" ] &&
		[ -r "$SVM_SYSROOT/usr/lib/libc.so" ] || {
		error "Missing staged SVM musl interpreter"
		return 1
	}
}

svm_guest_profile() {
	svm_require || return 1
	local wrapper="$SVM_SYSROOT/usr/bin/svm-gcc"
	local real_cc="${CC:-${CROSS_COMPILE}gcc}"
	if [ "$real_cc" = "$wrapper" ]; then
		real_cc=${REALGCC:-}
		[ -n "$real_cc" ] && [ "$real_cc" != "$wrapper" ] || {
			error "Missing native compiler while reusing SVM profile"
			return 1
		}
	fi
	case "$real_cc" in
	/*) ;;
	*) real_cc=$(command -v "$real_cc") || {
		error "Guest GCC not found: $real_cc"
		return 1
	} ;;
	esac
	export REALGCC="$real_cc" SVM_PLUGIN SVM_SYSROOT
	export CC="$wrapper"
}
