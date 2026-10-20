# Building SWMMU packages

SWMMU packages are opt-in and x86_64 only. Build the kernel plugin and guest
packages with a GCC toolchain whose plugin ABI matches; use the same GCC for
the plugin compatibility check and for `SWMMU_GCC`. The check below loads the
plugin in GCC before a long package build so mismatches fail early.

## Prepare headers and plugin

Use absolute paths. `SWMMU_UAPI` must end in `/include` and `SWMMU_PLUGIN`
must point to the plugin built by the configured kernel output tree.

```sh
export SWMMU_KERNEL_SRC=/src/linux
export SWMMU_KERNEL_BUILD=/build/linux
export SWMMU_UAPI=/build/swmmu/uapi/include
export SWMMU_PLUGIN=$SWMMU_KERNEL_BUILD/scripts/gcc-plugins/swmmu_plugin.so
export SWMMU_GCC=/usr/bin/gcc
export SWMMU_SYSROOT=/build/swmmu/sysroot

make -C "$SWMMU_KERNEL_SRC" O="$SWMMU_KERNEL_BUILD" ARCH=um \
	HOSTCC="$SWMMU_GCC" HOSTCXX=/usr/bin/g++ \
	scripts/gcc-plugins/swmmu_plugin.so
scripts/swmmu-prepare.sh headers
```

Build the kernel plugin inside the same toolchain container used for package
compilation. This keeps the GCC plugin ABI and compiler version aligned. The
container needs the GCC plugin development headers (`gcc`/`g++` packages).

## Create the instrumented musl sysroot

The sysroot starts empty. Building the `musl-nommu` split package with
`SWMMU=1` stages musl headers, startup objects, libraries, and SWMMU runtime
headers into `SWMMU_SYSROOT` through `swmmu_stage_musl()`.

```sh
export SWMMU_SYSROOT=/build/swmmu/sysroot
mkdir -p "$SWMMU_SYSROOT"
export SWMMU_UAPI SWMMU_PLUGIN
cd "$APORTS/main/musl"
SWMMU=1 abuild -r
"$APORTS/scripts/swmmu-prepare.sh" check
```

The same environment variables must be visible inside the `abuild` process.
Do not reuse a sysroot built with another musl version or plugin. Remove it and
rebuild `musl-nommu` when either input changes.

## Build OpenSSL, then nginx

The SWMMU OpenSSL recipe builds instrumented shared libraries and stages them
along with headers into the guest sysroot. Nginx then links against those
libraries. Nginx's configure probes may use the native builder's ordinary
`openssl-dev`; the guest compile and final link resolve headers and libraries
from `SWMMU_SYSROOT` through the SWMMU wrapper.

```sh
cd "$APORTS/main/openssl"
SWMMU=1 SWMMU_ONLY=1 abuild -r

cd "$APORTS/main/nginx"
SWMMU=1 SWMMU_ONLY=1 abuild -r

cd "$APORTS/main/coreutils"
SWMMU=1 SWMMU_ONLY=1 abuild -r

cd "$APORTS/main/zlib"
SWMMU=1 SWMMU_ONLY=1 abuild -r

cd "$APORTS/main/apk-tools"
SWMMU=1 SWMMU_ONLY=1 abuild -r

cd "$APORTS/main/python3"
SWMMU=1 SWMMU_ONLY=1 abuild -r
```

`SWMMU_ONLY=1` builds only the opt-in x86_64 guest package and avoids the
ordinary multi-architecture package variants. Install `musl-nommu`,
`libcrypto3`, `libssl3`, `zlib-nommu`, `nginx-nommu`, `coreutils-nommu`, and
`apk-tools-nommu` into the guest rootfs. The SWMMU zlib build stages its
headers, shared library, and pkg-config metadata for apk-tools. The apk-tools
guest build disables Lua, Python, docs, tests, and the static executable; it
provides the dynamic `/sbin/apk` and `libapk` runtime.
The coreutils recipe builds its commands separately from the normal Alpine
package and disables optional ACL, xattr, OpenSSL, and LTO support while the
SWMMU profile expands. Its I/O buffer is reduced from 256 KiB to 4 KiB for the
NOMMU process stack. The nginx
SWMMU config enables HTTP on port 8080 and HTTPS on port 8443; install a
certificate and private key at `/etc/nginx/swmmu.crt` and
`/etc/nginx/swmmu.key` before starting nginx.

## Check an existing toolchain

Set `SWMMU_KERNEL_SRC`, `SWMMU_KERNEL_BUILD`, `SWMMU_UAPI`, `SWMMU_SYSROOT`,
`SWMMU_PLUGIN`, and `SWMMU_GCC`, then run:

```sh
"$APORTS/scripts/swmmu-prepare.sh" check
```

This verifies the exported SWMMU UAPI, musl runtime files and startup objects,
and asks GCC to load the instrumentation plugin. `scripts/swmmu-profile.sh`
contains the shared compiler-wrapper and staged-musl setup used by package
recipes.
