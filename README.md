# qemu-static-windows

Reproducible static Windows builds of QEMU using tracked submodule patches and
either a Windows-container or WSL/Linux-Docker toolchain.

## Host Requirements

- Git
- CMake

Windows-container path:

- Windows with Docker configured for Windows containers

WSL/Linux-Docker path:

- Windows with WSL installed
- A distro name passed through `QSW_WSL_DISTRO`
- Docker available inside that WSL distro and connected to a Linux daemon

Enable long paths before syncing submodules:

```powershell
git config --global core.longpaths true
git config core.longpaths true
```

## One-Time Setup

Initialize submodules:

```powershell
git submodule update --init --recursive --depth 0
```

Prepare the Windows-container image:

```powershell
docker tag mcr.microsoft.com/windows/servercore:ltsc2022 qemubuild-windows
docker volume create tmp
docker volume create libs
docker volume create dist
docker build -t qemubuild -f docker/windows/Dockerfile docker/windows
```

Use a base image that matches the host OS. The GitHub Actions Windows job pins
`windows-2025`, so it tags `mcr.microsoft.com/windows/servercore:ltsc2025`
as `qemubuild-windows` before building `docker/windows/Dockerfile`.

Prepare the WSL/Linux-Docker image from WSL shell:

```sh
docker volume create tmp
docker volume create libs
docker volume create dist
docker build -t qemubuild-linux -f docker/linux/Dockerfile docker/linux
```

## Build

Windows-container path from PowerShell:

```powershell
cmake -P build.cmake
```

WSL/Linux-Docker path from PowerShell:

```powershell
$env:QSW_WSL_DISTRO='Ubuntu'
cmake -P build.cmake
```

Optional overrides:

- `QSW_DOCKER_BACKEND=windows|wsl|linux`
- `QSW_WSL_DISTRO=<distro-name>`
- `QSW_WSL_MIRROR_ROOT=<wsl-path>`
- `QSW_DOCKER_IMAGE=<image-tag>`
- `QSW_QEMU_VERSION=<tag|branch|commit>` defaulting to `v11.0.0`

Before the QEMU build starts, `build.cmake` resolves `QSW_QEMU_VERSION` and
checks out `sources/qemu` to that ref. The default tracks the current latest
QEMU release tag, `v11.0.0`.

Successful builds install into the Docker `dist` volume and then copy the
final tree to `out/`.

## Backend Notes

- On a Windows host, `build.cmake` defaults to the Windows-container backend
- Setting `QSW_WSL_DISTRO` or `QSW_DOCKER_BACKEND=wsl` switches the build to
	the WSL/Linux-Docker backend
- On the WSL backend, `build.cmake` mirrors `sources/` and `toolchains/` into a
	persistent WSL-local directory and mounts that mirror into Docker. This keeps
	most file I/O off the Windows filesystem while still rebuilding from the same
	checkout
- The default WSL mirror root is `$HOME/.cache/qemu-static-windows`, and can be
	overridden with `QSW_WSL_MIRROR_ROOT`

## Patch Workflow

Submodule fixes are kept as patch files instead of ad-hoc manual edits. The
build script applies them automatically and treats already-applied patches as a
success.

Current patch sets:

- `patches/anglembed/`
- `patches/libslirp/`
- `patches/qemu/`
- `patches/virglrenderer/`

When a submodule update needs a new fix:

1. Edit the submodule working tree
2. Verify the build with `cmake -P build.cmake`
3. Regenerate the tracked patch from the submodule diff

Examples:

```powershell
git -C sources/anglembed diff -- angle/src/image_util/AstcDecompressor.h > patches/anglembed/0001-fix-missing-cstdint-include-for-ASTC.patch
git -C sources/deps/libslirp diff -- meson.build > patches/libslirp/0001-make-iconv-optional-for-static-windows-cross-builds.patch
git -C sources/deps/virglrenderer diff -- src/drm/drm-uapi/drm.h src/vrend/vrend_renderer.c > patches/virglrenderer/0001-add-win32-ioctl-compat-for-drm-uapi.patch
git -C sources/qemu diff -- meson.build python/scripts/mkvenv.py > patches/qemu/0001-static-windows-build-fixes.patch
```

## Backend-Specific Notes

- Windows-container builds rebuild `virglrenderer` and `qemu` from clean build
	directories and rewrite Meson thin archives from `csrDT` to `csrD`
- Windows-container qemu builds still carry `--disable-gnutls` and
	`--extra-ldflags=-liconv`
- WSL/Linux-Docker builds use `docker/linux/Dockerfile`, read the Meson cross
	file from `toolchains/x86_64-w64-mingw32.txt`, and apply the `libslirp`
	patch because this MinGW toolchain does not ship a usable `libiconv` for the
	Windows target

## GitHub Actions

- `.github/workflows/build-release.yml` builds the Linux Docker backend on
	GitHub-hosted Ubuntu runners and the Windows-container backend on a
	`windows-2025` runner
- The Windows job uses step-level `docker build` and `docker run` rather than
	`jobs.<job>.container`, and the Windows container base image must match the
	host runner OS
- The workflow uploads the packaged `out/` tree as an artifact on pushes and
	pull requests
- Tag pushes matching `v*` also create a GitHub release and attach the zip
	archive

## Special Thanks

This repository was heavily informed by [okuoku/qemubuild](https://github.com/okuoku/qemubuild).  
Thanks to okuoku for publishing the original groundwork and making the Windows static-build flow far easier to study, adapt, and extend.