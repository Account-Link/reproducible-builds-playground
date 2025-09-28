Short answer: yes—you can replace most of this repo’s Docker/BuildKit machinery with mkosi, but only if you’re OK producing an OS image (DDI/disk/tar/dir) rather than a native OCI-layered image. If your downstream (e.g. DStack) truly *needs* OCI layers and registry pushes, you’ll need a conversion step. Otherwise mkosi gives you a cleaner, declarative path to bit-for-bit images with snapshot-pinned packages and a build script to reproduce the Node bits.

# What your repo is doing (in one line each)

* Deterministic Docker builds for a tiny Node app by **pinning base image + Debian snapshot + exact apt/npm versions**, cleaning caches, normalising timestamps (SOURCE_DATE_EPOCH + buildx `rewrite-timestamp`), and verifying with a second `--no-cache` rebuild + layer diffs.
* Optional **offline** mode with vendored deps; remote-machine and DStack verification helpers.

# How mkosi maps to this

* **Pin the distro + snapshot** in mkosi config (Debian/Ubuntu/Fedora etc.); mkosi calls the native package manager and can build *bit-for-bit* reproducible filesystem/disk images when you control `SourceDateEpoch`, repos, and package sets.
* **Two-stage build**: put your npm build in `mkosi.build` (runs in a clean build image), then artifacts are injected into the final image—no hand-rolled cache scrubbing needed.
* **Output formats**: directory/tar/cpio/disk (DDI). DDI boots under `systemd-nspawn` and VMs and is explicitly “container-bootable”, but mkosi doesn’t emit multi-layer OCI by itself.

# Gaps vs your current tooling (be blunt)

* **OCI layers/registry**: Docker/BuildKit gives you layers and `push`. mkosi gives you a tar/directory/disk; you must **import/convert** if your pipeline requires OCI (e.g., `podman import` or `skopeo/umoci`). If DStack expects an OCI digest, you’ll have to adapt that part.
* **Layer-level diffs**: your `diff-tools/*` compare OCI layers. With mkosi you’d diff filesystem trees or disk images; use `systemd-dissect` + checksums instead.

# Minimal mkosi drop-in for this project

Create these at repo root:

**mkosi.conf**

```
[Distribution]
Distribution=debian
Release=bookworm
Mirror=http://snapshot.debian.org/archive/debian/2024/12/01/

[Output]
# Pick one:
Format=directory         # or: tar, disk (DDI)
Output=mkosi.output

[Content]
Packages=
  ca-certificates
  curl
  nodejs
WithDocs=no

[Build]
# Ensures deterministic paths/umask etc.
SourceDateEpoch=1701475200   # 2023-12-01T00:00:00Z (match your repo’s convention)
```

**mkosi.build**

```bash
#!/usr/bin/env bash
set -euxo pipefail

# 1) Add app sources into the build tree deterministically
rsync -a --delete \
  --chmod=Fu+rw,Fg-w,Fu-x \
  --exclude node_modules \
  "$SRCDIR/simple-app/" "$BUILDDIR/app/"

# 2) Option A: Online, with exact versions
cd "$BUILDDIR/app"
npm ci --omit=dev --ignore-scripts
# Normalise mtimes for reproducibility
find . -print0 | xargs -0 touch -d "@$SOURCE_DATE_EPOCH"

# 3) Install into the image root under /opt/app
install -d "$DESTDIR/opt/app"
cp -a . "$DESTDIR/opt/app/"

# 4) Add a simple service (if you want bootable image)
install -d "$DESTDIR/etc/systemd/system"
cat > "$DESTDIR/etc/systemd/system/simple-app.service" <<'EOF'
[Unit]
Description=Simple deterministic app
After=network-online.target
[Service]
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/server.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
```

**mkosi.extra/**

```
# optional: drop static files, configs, compose equivalents here
```

Run:

```
mkosi summary
mkosi -f build
# Validate:
systemd-dissect --json=pretty mkosi.output    # directory or disk image
sha256sum mkosi.output/* | sort
```

Refs for verbs/formats and DDI/container-bootable images.

# If you still need OCI images

Two pragmatic options:

1. **Import the tar**: `podman import mkosi.output.tar yourrepo/simple-app:pin` → then push. Reproducibility relies on mkosi output being bit-for-bit; the import must use a fixed toolchain. (You lose “nice” layering.)
2. **Buildah rootfs**: use mkosi `Format=directory`, then `buildah from scratch && buildah add ...` with fixed timestamps/owners (respect `SOURCE_DATE_EPOCH`) → `buildah commit` → push. (You regain an OCI manifest but still no meaningful deterministic *layers* unless you strictly script file order/mtimes.)

# Verification parity (your scripts → mkosi)

* “Double build and compare”: run `mkosi -f build` twice; compare `sha256sum` of the resulting tar/disk or `btrfs` subvolume. Forensics with `systemd-dissect` instead of `tar --list` on OCI layers.
* **Snapshot pinning**: set `Mirror=` to the *Debian snapshot* date (exactly what you were doing in Dockerfile).
* **Dependencies manifest**: `mkosi dependencies` prints the package set required to build/boot; stash alongside your build manifest for audits.

# When mkosi is the better tool

* You want **OS-level images** (VM/metal/nspawn) and reproducible provisioning from *distro packages*, not layered OCI semantics.
* You prefer a **single declarative config** + build script over bespoke Dockerfile tricks to normalise timestamps/caches.

# When to stick with Docker/BuildKit

* Your pipeline, scanners, and DStack integration **expect OCI images + registries + layer diffs** and you don’t want an import step. Your current repo already solves this cleanly.

Want me to drop in a PR that adds `mkosi.conf`, `mkosi.build`, and a Makefile target (`make image`, `make oci-import`)?
