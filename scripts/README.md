Entry point scripts:

- `bootstrap.sh`: bootstrap a cross-compilation toolchain.
- `mkimage.sh`: main entry point script for creating tarballs and images.
- `genrootfs.sh`: generate a rootfs based on a list of packages.
- `genapkovl-*.sh`: generate apkovl for specific profiles.
- `mkimage-yaml.sh`: generate `latest-releases.yaml` with release metadata.

Internal helpers, not intended to be invoked directly:

- `mkimg.base.sh`: shared common logic.
- `mkimg.*.sh`: declare individual profiles.

# SWMMU build helpers

For compiler-plugin instrumented NOMMU userspace, start with
[`swmmu-prepare.sh`](swmmu-prepare.sh) and follow
[`../docs/swmmu-build.md`](../docs/swmmu-build.md). The `headers` command
exports the configured kernel's UAPI; `check` verifies the plugin, GCC ABI,
headers, runtime, and staged musl sysroot before building packages.
