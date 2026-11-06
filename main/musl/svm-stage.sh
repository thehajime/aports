#!/bin/sh
# SPDX-License-Identifier: MIT
# Called from the SVM musl build directory after installing its sysroot.
set -eu
svm_stage=$1
svm_interpreter=${2:-/lib/ld-musl-x86_64.so.1}
case "$svm_stage" in /*) ;; *) echo 'SVM_SYSROOT must be absolute' >&2; exit 1 ;; esac
case "$svm_interpreter" in /*) ;; *) echo 'SVM_INTERPRETER must be absolute' >&2; exit 1 ;; esac
case "$svm_stage$svm_interpreter" in
  *[[:space:]]*) echo 'SVM paths must not contain whitespace' >&2; exit 1 ;;
esac
svm_lib=$svm_stage/usr/lib
svm_inc=$svm_stage/usr/include
svm_bin=$svm_stage/usr/bin
mkdir -p "$svm_lib" "$svm_bin"
if [ -n "${SVM_UAPI:-}" ]; then
	case "$SVM_UAPI" in
	/*) ;;
	*) echo 'SVM_UAPI must be an absolute exported header path' >&2; exit 1 ;;
	esac
	[ -r "$SVM_UAPI/linux/version.h" ] &&
		[ -r "$SVM_UAPI/asm/unistd.h" ] || {
		echo 'SVM_UAPI must contain headers_install output' >&2
		exit 1
	}
	cp -a "$SVM_UAPI/." "$svm_inc/"
fi
cp libssp_nonshared.a "$svm_lib/"
cat > "$svm_lib/svm-note.S" <<'ASM'
.section .note.svm,"a",@note
.balign 4
.long 4,8,1
.asciz "SVM"
.balign 4
.long 2,208
.section .note.GNU-stack,"",@progbits
ASM
${CC:-gcc} -c "$svm_lib/svm-note.S" -o "$svm_lib/svm-note.o"
# Based on musl's specs; use the staged libc, advertise its ABI and select
# rcrt1.o plus the static PIE link flags when requested.
cat > "$svm_lib/svm-gcc.specs" <<SPECS
%rename cpp_options old_cpp_options

*cpp_options:
-nostdinc -isystem $svm_inc -isystem include%s %(old_cpp_options)

*cc1:
%(cc1_cpu) -nostdinc -isystem $svm_inc -isystem include%s

*link_libgcc:
-L$svm_lib -L .%s

*libgcc:
libgcc.a%s %:if-exists(libgcc_eh.a%s)

*startfile:
%{!shared:%{static-pie:$svm_lib/rcrt1.o;:$svm_lib/Scrt1.o}} $svm_lib/crti.o crtbeginS.o%s $svm_lib/svm-note.o

*endfile:
crtendS.o%s $svm_lib/crtn.o

*link:
-dynamic-linker $svm_interpreter -nostdlib %{shared:-shared} %{static:-static} %{static-pie:-static -pie --no-dynamic-linker -z text} %{rdynamic:-export-dynamic}

*esp_link:


*esp_options:


*esp_cpp_options:


SPECS
cat > "$svm_bin/svm-gcc" <<'WRAPPER'
#!/bin/sh
set -eu
: "${SVM_PLUGIN:?Set SVM_PLUGIN to the plugin matching REALGCC}"
svm_bin=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# Memory operations must reach the instrumented libc rather than late RTL
# expansion into native-address string instructions.
exec "${REALGCC:-gcc}" -fPIE -fplugin="$SVM_PLUGIN" \
	-fno-builtin \
	"$@" -specs "$svm_bin/../lib/svm-gcc.specs"
WRAPPER
chmod 755 "$svm_bin/svm-gcc"
