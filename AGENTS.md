# Aports NOMMU package work and UML verification

These instructions capture the cloud workflow used for the BusyBox and musl NOMMU proposal. Recheck paths, versions, hashes, and kernel configuration in each task: cloud scratch files are not durable, and generated outputs may belong to an earlier source revision.

## SWMMU application profile

The end goal is for every userspace program run by SWMMU to be compiler-plugin instrumented. Expand coverage incrementally, starting with required libraries and core utilities; do not assume that packages built with the ordinary Alpine compiler are compatible. Use the opt-in `SWMMU=1`/`SWMMU_ONLY=1` recipes and `scripts/swmmu-profile.sh` so guest flags do not leak into host build tools. The reusable toolchain preparation script is [`scripts/swmmu-prepare.sh`](scripts/swmmu-prepare.sh); sysroot setup and package order are documented in [`docs/swmmu-build.md`](docs/swmmu-build.md).

For SWMMU coreutils work, build only the required command subset first and keep it separate from the normal `coreutils` package. Preserve Alpine's usual package behavior when `SWMMU` is unset. Add commands as runtime coverage requires, then validate them in the guest and record any unsupported syscall or compiler access before broadening the set.

### TODO: GCC SWMMU instrumentation for generated stack probes

Coreutils' `wc` required a temporary `-fno-stack-clash-protection` workaround. GCC can emit stack-clash probe instructions in the function prologue (for example, an instruction such as `orq $0, (%rsp)`) after the SWMMU GIMPLE pass has run. The pass currently inserts checks around GIMPLE memory references; a later backend-generated probe therefore is not rewritten through the SWMMU runtime. On the NOMMU UML guest this uninstrumented access caused `wc` to segfault, followed by UML's `Attempted to kill init` panic. The final working package uses the compiler flag workaround; see the conditional SWMMU branch in `main/coreutils/APKBUILD` and the run-specific `coreutils-run/wc-only.log` / `wc-probes.log` when available.

Follow-up investigation for the compiler/plugin task:

- Reproduce with a clean, checksum-verified coreutils source and the matching Alpine GCC/plugin ABI. Build `wc` once with the current profile and once with `-fstack-clash-protection`; preserve the exact compiler command, GCC version, plugin version, and generated assembly (`-save-temps` or `objdump -dr`).
- Locate when the probe first appears in GCC's pass dumps. The plugin currently registers its regular `GIMPLE_PASS` after the first `ssa` pass, while SWMMU all-access mode uses an IPA pass after `inline` (`scripts/gcc-plugins/swmmu_plugin.c`). Determine whether probing is introduced during RTL expansion/prologue generation or an earlier pass for the exact GCC version.
- Evaluate a GIMPLE-side approach that makes probe accesses visible before lowering, and/or a late RTL pass that recognizes and instruments generated stack-probe memory operations. Keep probe sequences, stack pointer updates, CFA/unwind metadata, and stack-clash guard-page semantics correct; do not blindly instrument every `%rsp`-relative access.
- Add a focused compiler-plugin regression test that compiles a function with a large/dynamic stack allocation, verifies generated probe accesses are routed through SWMMU, and runs the binary in a SWMMU guest. Include both fixed and dynamic allocations and probe sizes spanning one or more guard pages.
- Remove the package-level `-fno-stack-clash-protection` workaround only after assembly inspection and guest runtime coverage pass with stack-clash protection enabled. Keep the coreutils 4 KiB `IO_BUFSIZE` workaround separate: it addresses NOMMU user-stack capacity, not missing instrumentation of generated probe instructions.

### UML SMP configuration note

In the Linux kernel tree, `arch/um/Kconfig` declares `UML_SUBARCH_SUPPORTS_SMP` and makes `SMP` depend on it. The x86 UML subarchitecture selects that capability in `arch/x86/um/Kconfig` only when `X86_CX8 && MMU` is enabled. Consequently current x86 NOMMU UML configurations (plain NOMMU and SAS/SWMMU) cannot enable kernel SMP; the limitation is a Kconfig/platform capability constraint, not just a default setting. Ordinary MMU UML can select SMP and runs vCPUs as host threads.

### TODO: Reconcile UML SMP Kconfig with upstream `uml/next`

The local `feature-swmmu-nommu` tree restricts `UML_SUBARCH_SUPPORTS_SMP` to `X86_CX8 && MMU` in `arch/x86/um/Kconfig`. Upstream UML's current `next` branch selects it with `X86_CX8` alone, so plain x86 NOMMU UML can select SMP there. Treat this as a likely incomplete feature-branch carry-over, not a fundamental UML NOMMU limitation. Before changing it, compare the relevant UML SMP commits and dependencies in the exact upstream base being integrated; check whether the SWMMU/SAS subarchitecture also needs its own SMP enablement or runtime fixes. Then build and boot plain NOMMU with `CONFIG_SMP=y` and multiple `ncpus`, confirm CPUs online and run a small workload comparison. Keep SAS/SWMMU SMP as a separate question: the MMU UML wrk result only shows that SMP can help this workload when vCPUs run concurrently; it does not establish that SAS/SWMMU SMP is implemented or correct.

For automated nginx measurements, use a dedicated opt-in job/template rather than running UML as a side effect of every generic package build. The job needs a matching UML kernel/plugin, an Alpine GCC toolchain with matching plugin ABI, an instrumented musl/OpenSSL sysroot, `CAP_SYS_RAWIO` for `zpoline=1`, and a separate client/container on a reachable network. Publish raw wrk output and machine-readable summary as CI artifacts; treat short samples as regression indicators, not performance claims. Keep changes to the active CI definition as a reviewable patch if another task is editing it concurrently.

## Start by preserving the checkout

Before editing or building, record the repository state and identify existing local work:

```sh
git status --short --branch
git branch --show-current
git rev-parse HEAD
git log -5 --oneline --decorate
```

Do not clean, reset, overwrite, or stage unrelated untracked files. Keep build trees, downloaded source archives, root filesystems, logs, and UML outputs outside this repository, under a task-specific directory such as `/workspace/cloud-setup/<run-id>/`. Stage only files intended for the current change. For the upstream proposal, keep commits separate: one commit for the BusyBox package, one for musl, and one for BusyBox patch additions.

## Establish the exact source being tested

Use the version URL and checksum in the target branch's `APKBUILD`; do not infer source contents from a Git mirror's moving `master`, an old `src/` build directory, or a previous test artifact. Verify downloaded source archives against the APKBUILD checksum, extract each test into a new clean directory, and compare the relevant source file with the archive when a prior patch may have touched it.

For the Alpine aports master snapshot used in this work, BusyBox was pinned to `busybox-1.38.0.tar.bz2` (SHA-512 `ba3866f0a9ceabafe8c4d43afaf031bc5554742903b3d08e59a8592351dc09c6e091bb0cd2852b3ed1e79e841de871bac4dc48d9bb1cef9309c3f8495aba0d00`). The BusyBox Git history fix for NOMMU hush re-exec is already represented in the 1.38.0 release by `G.reexeced_on_NOMMU`; a separate re-exec patch is unnecessary for this source. The hush `cd -` / `OLDPWD` behavior is a separate issue: the clean 1.38.0 archive lacks it, and the proposed `0000-hush-fix-oldpwd.patch` is needed for the hush test described below. Ash supports `cd -`, but BusyBox disables ash when `CONFIG_NOMMU=y`; an MMU ash run is only a comparison.

Treat test reports from a modified source tree as suspect until repeated from a checksum-verified clean extraction. In particular, an earlier test record initially misstated the 1.38.0 re-exec source; the later Git history and release-source check corrected it. The corrected result is recorded in the aports proposal commit-layout log in the Obsidian vault.

## Build BusyBox and musl

The SWMMU GCC plugin used by these guest binaries is dynamically linked against musl. Host Debian/Ubuntu GCC cannot load it. Build plugin-instrumented targets inside the prepared Alpine image (`aports-dev:edge`, observed as Alpine `3.25.0_alpha20260805` with GCC 15.2.0), while using a separate Ubuntu/glibc environment for the UML kernel. Check that the image and plugin still match the current task before reuse.

The known package build limitation was access to Alpine edge build dependencies through the in-container proxy. A compiled NOMMU BusyBox binary and staged musl library do not prove that signed APKs or a complete `abuild rootpkg` transaction succeeded. Report package compilation, APK creation/signature, and guest execution as separate results. Do not weaken APK signature, TLS, or archive checksum verification to work around network failures.

For SWMMU-instrumented guest outputs, the prior workflow used the shared helper artifacts under `/workspace/cloud-setup/aports-master/` (compiler plugin, exported kernel UAPI, and musl sysroot) plus the `swmmu_guest_profile()` logic in `scripts/swmmu-profile.sh`. The helper files may be absent in a fresh task and were not part of the upstream-only proposal commits. Inspect their current contents and provenance before use; regenerate wrappers/specs for the current absolute paths rather than reusing generated files with stale paths. Keep guest compiler flags and plugin settings out of `HOSTCC`/host tools. The profile expects absolute paths for the plugin, UAPI, and sysroot and validates the exported headers, runtime headers, musl startup objects, libraries, and interpreter.

The minimal direct BusyBox build shape, when the source tree, output directory, wrapper, and dependencies have been prepared, is:

```sh
docker run --rm \
  -v /workspace/cloud-setup/<run-id>:/workspace/cloud-setup/<run-id> \
  aports-dev:edge sh -ec '
    run=/workspace/cloud-setup/<run-id>
    make -C "$run/busybox" O="$run/out" HOSTCC=gcc silentoldconfig
    make -C "$run/busybox" O="$run/out" HOSTCC=gcc CC="$run/swmmu-cc"
  '
```

Use separate output directories and configs for NOMMU hush and any MMU ash comparison. Confirm the final `.config` after `silentoldconfig` (`CONFIG_NOMMU=y`, `CONFIG_HUSH=y` for the NOMMU case). This direct target build is useful for runtime validation; it does not replace building the package through aports when dependencies are available.

## Prepare and run the UML guest

Build the UML kernel with Ubuntu/glibc tools, then link it statically. Alpine-built UML kernels were not the validated path here. A previously validated static kernel is `/tmp/aports-3.24/kernel-ubuntu/linux`, SHA-256 `9578c987d332a83ee409185bc744fad21f6663023297a0cc8e83afb0351917f1`. Reuse it only after checking its hash, source revision, and `.config`; the config used `CONFIG_STATIC_LINK=y`, `CONFIG_HOSTFS=y`, `CONFIG_UML_NOMMU_SAS=y`, and `CONFIG_NOMMU_SWMMU=y`. A fresh task should build or explicitly verify a kernel with the required options rather than assuming this scratch artifact still exists.

Prepare a task-specific Alpine minirootfs and copy only the test binaries, required libraries, and init script into it. Do not overwrite shared `/bin/busybox` or reuse a mutable rootfs without recording its state. Ensure the init script prints a unique start/result marker, captures each test's exit code, and powers off using the guest's actual BusyBox path (typically `/bin/busybox poweroff -f`). Missing executables or a bad poweroff path can leave UML looping until timeout.

The validated headless launch pattern was:

```sh
docker run --rm --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  --tmpfs /dev/shm:rw,nosuid,nodev,exec,size=2g \
  -v /path/to/static/vmlinux:/vmlinux:ro \
  -v /path/to/task-rootfs:/rootfs:rw \
  ubuntu:24.04 timeout 240s /vmlinux \
    uml_dir=/tmp/uml root=/dev/root rootflags=/rootfs rootfstype=hostfs rw \
    mem=2048m loglevel=4 init=/root/test-init
```

Do not use `-it` in the managed non-TTY shell; it fails with “the input device is not a TTY.” Check both the host Docker/UML exit status and the guest's explicit test-result and normal-poweroff markers. Preserve full stdout/stderr in a run-specific log and capture the command exit status directly, without a pipeline that masks it.

For the BusyBox hush check, exercise `cd /tmp`, `cd /`, `cd -`, then verify both `PWD` and `OLDPWD`. The recorded clean-source NOMMU hush run failed `cd -` with exit 13; applying the proposed oldpwd patch and rebuilding passed with exit 0. The MMU ash comparison passed, but is not evidence ash is available in the NOMMU binary. The separate Alpine edge smoke used `lmbench_run.sh` and reported 10 selected commands passing. These checks do not establish full APK integration or full-suite coverage.

## Record outcomes and boundaries

Keep commands, source hashes, kernel hash/config, build logs, guest logs, and a concise result in a task-specific run record. Clearly distinguish:

- package target compilation from a complete signed APK build;
- guest runtime checks from packaging/install transaction checks;
- hush NOMMU behavior from an MMU ash comparison;
- passed, failed, blocked, and unrun checks.

The prior package build could not fetch all Alpine edge dependencies through the in-container proxy, so complete signed BusyBox/musl APK builds were not verified. GitHub Actions, KUnit, and kselftests were outside the requested verification and were not run. Do not claim them as passed or start them unless a future task asks for them. Do not push to GitLab unless that task requests it; the user previously said they would handle that push later.
