# Aports NOMMU package work and UML verification

These instructions capture the cloud workflow used for the BusyBox and musl NOMMU proposal. Recheck paths, versions, hashes, and kernel configuration in each task: cloud scratch files are not durable, and generated outputs may belong to an earlier source revision.

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
