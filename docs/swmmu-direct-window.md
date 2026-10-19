# Experimental kernel-authorized direct accesses

This is an opt-in common SWMMU toolchain profile. Applications use the same
compiler wrapper; they do not need source lists, allocator annotations, or
application-specific address constants. All-access instrumentation remains
enabled. Unsupported accesses retain the runtime helper path.

## Matching components

- The `swmmu-nommu-exp` Linux branch with the reserved-alias-window query and
  dirty same-mm alias repair, and its exported UAPI.
- The matching `swmmu_plugin.so`, built using the guest GCC version and libc.
- The musl runtime patch series and installed `swmmu_direct_window_guard.h`.
- Single-CPU x86_64 UML SAS, booted with `swmmu_direct=1`. This reserves virtual
  address space without allocating an equivalent amount of RAM.

The kernel publishes an immutable interval containing only active guest aliases
or inaccessible guards. Mapping permissions, backing replacement on address-space
switch, and eager private-fork copies enforce isolation. Unmapping an alias must
restore its guard. This is a backend contract, not a cached VMA permission check.

## Common profile

Follow the sysroot, plugin and UAPI preparation in `swmmu-build.md`. Set
`SWMMU_DIRECT_WINDOW=1` alongside `SWMMU=1` for both the musl build and guest
package builds. Keep `HOSTCC` and `HOSTCXX` native. `swmmu_musl_flags` selects
hidden bound aliases during libc bootstrap; `swmmu_stage_musl` installs the
guard header. `swmmu_guest_profile` exports the setting to `scripts/swmmu-cc`,
which supplies the common header and `direct-window=1` plugin option.
The public key query is a compiler-only intrinsic. A late compiler pass replaces
it with an explicit GOT-based word read, avoiding executable copy relocations.
The hidden libc query uses RIP-relative addressing before relocation. Ordinary
CRT objects use the public query; `rcrt1.o` uses the hidden query before static
PIE self-relocation. The supplied Makefile patch selects this automatically.
Keep `--no-relax`.

The ordinary `SWMMU=0` package path is unaffected. Setting
`SWMMU_DIRECT_WINDOW=0` retains ordinary all-access lowering. This does not
disable the runtime's own guarded fallback optimization when the kernel offers
the reserved window. On an older backend, the query fails and zero bounds
retain helper behavior. Already linked instrumented applications need matching
runtime symbols; deploy the libc and application package set together.

## Access rules

The runtime publishes bounds for internal span checks and an atomic
`nommu_swmmu_direct_key` word for inline scalar checks. The key describes a
page-aligned power-of-two subset of the queried window. Its low six bits encode
the shift (at least 12), and its upper bits encode the address prefix (at least
2). Initially `UINTPTR_MAX` matches no 64-bit address. The compiler-only const
query allows scalar optimization to reuse the snapshot and derived prefix;
a final GIMPLE pass removes the call before RTL expansion. Cached initial
snapshots, including mixed initial/valid shift and prefix, fail closed. No
mutable VMA permission is cached, and applications must not write the key.
No numeric native-address cutoff or application source selection is used.
Scalar widths 1, 2, 4 and 8 that fit within one page and the key's subset use
direct x86 instructions. Precise memory operands allow ordinary compiler
optimization; volatile accesses retain opaque helper calls. Dynamic memcpy,
memset and memmove check complete spans before using direct copies. Outside
the window they retain the chunked helper implementation.

The reference header is dual-licensed in the kernel tree and supplied under
MIT here. Runtime-internal native helpers and window initialization must remain
excluded from instrumentation to avoid recursive bootstrap calls.

## Validation and limits

The source archive checksum and patched musl source tree are compared with the
measured source tree; the guard header differs only in its SPDX license choice.
The common flags were used to build musl, the CPython core and its configured
extension modules, then run Kirk cold-source startup in UML. Signed APK creation
and a complete package installation transaction remain separate checks; these
source-build experiments do not establish them.

The rebuilt complete musl SDK linked dynamic PIE and static PIE through the
common wrapper. Both completed a guest mmap/fork isolation smoke test with
key `0xa3`, and static PIE had no PT_INTERP. No compiler-only intrinsic symbols
remained unresolved. This does not validate every package startup path.

Run the kernel direct-window kselftest, existing SWMMU kselftest and KUnit, and
GCC plugin tests before deployment. Fork isolation, mprotect, munmap guards,
fixed replacement and mremap are required checks. A future lazy COW backend
must enforce read-only shared aliases before allowing direct stores. The
default-off aliasless-native-stack migration limitation remains unresolved;
this optimization is validated using the default-on SWMMU backend.

Performance evidence, exact hashes, configurations, commands and stop reasons
are recorded in the Obsidian `2026-10-19_114550+0900-kirk-post-scalar-direct-window`
run. First-test startup measurements deliberately stop the suite after the
first launch and are not full LTP results.
