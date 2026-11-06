# SVM musl bootstrap on UML

Opt in to the `musl-nommu` variant with `SVM=1 SVM_PLUGIN=/absolute/path/svm_plugin.so` and a matching GCC/plugin ABI. `SVM_SYSROOT=/absolute/path` optionally retains development files. `SVM=1` and `SWMMU=1` select separate implementations. The default package and ARM Buildroot lane remain separate.

The SVM patch adds a private root word in pthread Part 2, leaving the ordinary build's 200-byte TCB unchanged. The SVM x86_64 TCB is 208 bytes with the root at TP+200; compile-time assertions and the kernel architecture layout hook check that contract. The root reader and VA constants are architecture owned. The table walk and startup objects are built without the plugin.

Static startup installs the root before constructors. The dynamic loader installs it after final TLS copying/relocation and before transferring control to the application. Both use existing `PR_SVM_INSTALL_L1_TLS`; the kernel must retain PA mmap until that succeeds. An era-2 SVM note advertises the TCB size. A dynamically linked SVM executable also needs the matching note; this patch does not automatically add it to arbitrary application builds.

## Focused verification

Build `svm-bootstrap-smoke.c` with the same plugin and libc. It forces a 64 KiB TLS image and checks mmap VA load/store and munmap in a constructor, before main. Test both static PIE (using musl's `rcrt1.o`) and dynamic PIE against the staged SVM interpreter. Run only in the SAS UML guest with SVM enabled. Native execution is not supported.

For a static PIE, link the instrumented smoke object explicitly with `gcc -nostdlib -static-pie -Wl,--no-dynamic-linker`, followed by the staged `rcrt1.o`, `crti.o`, the smoke object, a group containing `-lc -lgcc -lgcc_eh` with the staged libc search directory, and `crtn.o`. The stock musl-gcc specs do not select `rcrt1.o` for `-static-pie` automatically.

For a dynamic PIE, use the staged musl-gcc and interpreter, and include an assembler object containing:

```asm
.section .note.svm,"a",@note
.balign 4
.long 4,8,1
.asciz "SVM"
.balign 4
.long 2,208
.section .note.GNU-stack,"",@progbits
```

Success prints `MUSL_SVM_BOOTSTRAP_OK` and exits 0. Define `SVM_SMOKE_MALLOC` to extend the same program with a 128 KiB malloc/write/read/free and stdio check. Record those results separately from bootstrap. The initially imported plugin faulted on mallocng free_meta aggregate zeroing in the static test. Kernel-tree plugin commit `2d9a314d6cb3` translates bounded empty-constructor stores; with that fix, both static and dynamic extended tests pass in the focused host-GCC lane. Other aggregate operations remain a separate coverage gate.

## Outstanding gates

This is a bootstrap stage, not complete libc SVM coverage. Basic thread TLS/stack/cancellation-point assembly boundaries and x86_64 pointer atomics are connected. Default-attribute and explicit-zero-guard threads pass TLS isolation, VA mmap, child nanosleep and parent join as static/dynamic PIE. Broader thread/cancellation/robust-mutex coverage, other bulk and aggregate accesses, fork/COW, runtime dlopen and broader applications remain open. Native loader/stack/data addresses retain PA identity in this UML stage; ENOENT in the reverse helper preserves that identity, while ambiguous or incomplete SVM reverse mappings remain fatal. Complete ELF data/stack virtualization and PA policy remain kernel/runtime follow-ups.

Focused source builds and guest tests do not establish a signed APK build/install transaction, an Alpine GCC package build, ARM compatibility, or CI completion. Preserve those as separate gates.

## Thread profile

`svm-pthread-smoke.c` covers default and explicit-zero-guard creation, TLS isolation, mmap data access, a child cancellation-point syscall and a waiting join. The generic C memcpy/memmove/memset implementations replace uninstrumented x86_64 assembly only in the SVM profile. Atomic assembly receives translated pointers. Clone receives native stack and TP addresses; each child inherits the root for its first C access, then reinstalls it through the checked API.

The UML SVM architecture profile defaults stack guards to zero. A nonzero explicit guard request returns EINVAL before allocation/clone: this backend cannot enforce the requested protection yet, and NOMMU mprotect returns ENOSYS. Ordinary musl retains its 8192-byte default. This profile choice does not change ARM/uClibc. Revisit the SVM guard default and request handling when real mprotect/protection support lands.

## Retained sysroot compiler

With `SVM_SYSROOT=/absolute/path`, the recipe also installs `libssp_nonshared.a`, an era-2 TCB-208 note object, GCC specs and `usr/bin/svm-gcc`. Set `SVM_PLUGIN` when invoking the wrapper (and `REALGCC` if needed) to the matching host compiler/plugin pair. It instruments guest code, selects the staged libc and adds the ABI note automatically. Keep host build tools on the ordinary compiler.

```sh
export SVM_PLUGIN=/absolute/path/svm_plugin.so
/absolute/sysroot/usr/bin/svm-gcc -O2 -static-pie svm-bootstrap-smoke.c -o smoke-static
/absolute/sysroot/usr/bin/svm-gcc -O2 -pie svm-bootstrap-smoke.c -o smoke-dynamic
```

This wrapper handles `rcrt1.o` and static-PIE linker flags; no manual note object or explicit startup-object link is needed for these commands. Shared links also receive the note. Sysroot/spec paths must be absolute without whitespace; regenerate the stage after relocating it. `SVM_INTERPRETER` selects the guest loader path (default `/lib/ld-musl-x86_64.so.1`), allowing a dedicated loader during side-by-side tests. An installed system-wide SVM loader is for the SVM userspace profile.

The wrapper and source/libc were verified with Alpine GCC 14.2, including static/dynamic bootstrap+malloc and pthread cases. The local signed APK gate is recorded below. Broader rootfs/application and CI coverage remain separate gates.

## Signed local APK gate

The actual recipe generated six 1.2.6-r8 APKs under Alpine GCC 14 with a local test key. After adding that public key to the isolated build environment, repository index signing and verification of all six APK signatures passed. Installing musl-nommu from that signed local repository into an empty root passed with normal verification enabled. The installed/stripped loader and the retained SVM SDK then passed static/dynamic bootstrap+malloc and pthread guest smokes (four exit-0 cases).

The initial index step rejected the untrusted local key; trusting its public key in the task environment repaired the index, and a subsequent abuild all returned up to date with exit 0. These are locally signed test packages, not official Alpine packages or a published repository. Private signing material remains local. The ordinary musl-dev package remains ordinary; use SVM_SYSROOT for the matching SVM static library/SDK. A complete instrumented Alpine rootfs and cloud userspace packaging lane remain follow-ups.

## Cancellation and signal smoke

`svm-cancel-signal-smoke.c` adds three actual runtime checks: deferred read cancellation with cleanup and join, a main-thread SIGUSR1 handler storing through an SVM VA, and a child-thread handler using its own TLS root for the same mapping. Build it with the retained SVM wrapper and `-O2 -pthread`, as both static PIE and dynamic PIE. Each emits TAP 3/3 and exits zero; when run directly as guest PID 1 it powers off on success. A failed check exits nonzero and must not be counted from the UML process exit code alone.

Both forms passed locally against the installed SVM musl/SDK with Alpine GCC 14.2 and the SAS UML kernel. The checks require the x86_64 SVM address window and are not an ARM FDPIC or general POSIX conformance test. They do not cover asynchronous cancellation, robust/shared mutexes, alternate signal stacks, signal storms, or fork/COW. The existing four-program package CI remains unchanged; these two standalone guest runs are separate local gates until private CI is configured. Source, binaries and logs must not be published to a public repository.

## Synchronization smoke

`svm-sync-smoke.c` puts the tested objects in an SVM VA mapping and covers a contended mutex handoff, condition wake/reacquisition, robust owner death/recovery, and a semaphore wait/wake. Compile with the retained wrapper and `-O2 -pthread`, separately as static PIE and dynamic PIE. The fixture emits TAP 4/4 and powers off on success when used as PID 1. Check TAP and normal powerdown, not just the UML exit code. Static PIE at `-O0` is an additional plugin-path check.

These checks require the kernel-tree plugin's atomic-builtin memory-operand fix: the earlier plugin leaves a C11 atomic access through the SVM mapping unconverted and faults before the first check completes. Both x86_64 forms and the `-O0` static form pass with the fixed matching Alpine GCC 14.2 plugin and the installed musl SDK. This does not rebuild the signed APKs or change the existing four-program package CI. Cross-process/shared futex identity, priority inheritance, aliasing and fork/COW remain separate gates. Preserve all source and evidence locally or in the private vault.

## Retained SDK for complete applications

Set `SVM_UAPI` to the integrated kernel's `headers_install` include directory
when staging the SDK. The wrapper uses `-nostdinc`; Linux/asm headers therefore
must be part of that target sysroot rather than inherited from the build host.
The optional directory is validated and copied alongside the musl headers.

The SVM wrapper disables implicit builtins so ordinary libc memory and string
calls reach the instrumented libc. This includes mempcpy, used by hush, whose
return value points past the copied bytes. At `-Oz`, GCC otherwise expands
variable-size zero/copy operations into raw `rep stos`/`rep movs` instructions
after the GIMPLE pass; a BusyBox xzalloc startup and a focused VA fixture
reproduce the resulting fault. Explicit compiler builtins and later generated
memory operations still need their own coverage; this policy does not claim
that broader closure. The compiler option policy is specific to this SVM SDK
and leaves ordinary musl packages unchanged.
