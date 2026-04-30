# Proton Affinity

A custom Proton build based on [proton-cachyos](https://github.com/CachyOS/proton-cachyos), with additional patches targeting Affinity (by Canva) on Linux

Previously, [I would patch Wine upstream directly](https://github.com/arecsu/wine-affinity), but their wayland implementation is still behind some experimental forks like [wine-em](https://github.com/Etaash-mathamsetty/wine-valve/). Many of the stuff that needs fixing to make Affinity work smoother needed work across the graphical and desktop stack. So, we better make sure we do this cleanly under Wayland, as X11 is deprecated and soon to be legacy software.

For that matter, I decided to use `proton-cachyos` as the foundational base, as it incorporates `wine-em` and includes more libraries (DXVK, VKD3D, etc), extra patches, anything to make sure we are pretty much covered and not missing anything in an attempt to run Affinity as complete as possible.

## Features

- Native Wayland. No XWayland needed, with lower input latency. Brushes and tools have no frame delay.
- No mouse jitter when moving floating panels or using tools simultaneously
- DXVK + VKD3D. Full hardware acceleration
- OpenCL working (NVIDIA tested; AMD/Intel untested)
- Native file dialogs from your desktop environment
- Color picker works. Screen capture implemented via Vulkan swapchain readback. Wayland
- Panel re-docking works. Floating windows and z-order implemented as Wayland subsurfaces
- Many fixes for hard locks and freezes when working with vectors
- Fixes for visible wrong path lines in some vectors
- Dropbox lock files cleaned up and hidden (see note below)
- Maximize no longer leaves a gap on the top/left of the window
- Fractional-scale edge artifacts on the canvas are gone (1-pixel lighter line at 125%/150%/175%)

## Affinity Patches

| # | Component | Description |
|---|-----------|-------------|
| 0001 | build | Fix gcc-14 `-Werror=discarded-qualifiers` in CachyOS EAC hack |
| 0002 | comdlg32 | Use XDG Desktop Portal for native file dialogs ([Alexander Wilms, Wine MR !10060](https://gitlab.winehq.org/wine/wine/-/merge_requests/10060)) |
| 0003 | winewayland | Fix pointer jitter and subsurface pointer coordinate compensation |
| 0004 | wintypes | Hack in calls to `RoResolveNamespace` ([ElementalWarrior](https://gitlab.winehq.org/ElementalWarrior/wine)) |
| 0005 | winewayland | Fix subsurface positioning for child windows |
| 0006 | d2d1 | Stub `Widen` with empty geometry to prevent caller freeze |
| 0007 | opencl | Implement `cl_khr_d3d10_sharing` extension for DXVK compatibility ([ElementalWarrior](https://gitlab.winehq.org/ElementalWarrior/wine)) |
| 0008 | opencl | Use substring matching for OpenCL/DXGI device name comparison ([ElementalWarrior](https://gitlab.winehq.org/ElementalWarrior/wine)) |
| 0009 | d2d1 | Prevent runaway Bézier splitting and recursion in geometry processing |
| 0010 | d2d1 | Implement cubic-to-quadratic Bézier subdivision for accurate path rendering ([noahc3/WineFix](https://github.com/noahc3/AffinityPluginLoader)) |
| 0011 | d2d1 | Fix collinear outline join placing vertices 25 units away on smooth continuations |
| 0012 | comdlg32 | Fix portal dialog compatibility and responsiveness for Affinity |
| 0013 | winewayland | Implement owned windows as subsurfaces with z-order and floating window support |
| 0014 | winewayland | Mark layered attributes set when `CreateWindowSurface` re-runs with `layered=TRUE` |
| 0015 | winewayland | Implement screen capture via Vulkan swapchain readback |
| 0016 | ntdll, server | Clean up and hide NTFS Alternate Data Stream files |
| 0017 | winewayland | Snap CSD maximized windows to monitor work area |
| 0018 | winewayland | Floor client subsurface position to hide fractional-scale edge gaps |
| 0019 | include | Fix `ntuser.h` C++ incompatibilities for gcc 14 / SteamRT 4: explicit casts on `UlongToHandle` returns, rename `virtual` variable |

### Dropbox lock files note

Affinity creates NTFS Alternate Data Stream files (e.g. `foo.af~lock~:com.dropbox.ignored`) as Dropbox lock markers. On Linux, Wine stores these as sibling files with a colon in the name. Patch 0016 makes Wine automatically delete these stream files when the parent document is closed, and marks them hidden from Wine's own filesystem view.

**Linux file managers (Nautilus, Dolphin, etc.) may still show these files.** They follow Unix hiding conventions: a leading dot, or in some implementations a trailing `~` at the end (I guess?). A colon in the middle of a filename doesn't match either convention, so file managers won't hide it. This is outside Wine's control; it would require changing how Wine names stream files on disk which is pretty hacky.

## Known Problems

These are issues I've identified myself. Expect more than what's listed here — Affinity on Linux is still far from a native-quality experience, but it's usable enough for real design work.

- Resizing the window is choppy and causes white flashes. Likely requires fixes in both Wine's Wayland driver and DXVK
- *(Wayland, fractional scale)* Maximize → shrink → maximize briefly shows a blurry canvas until DXVK recreates the swapchain to match the new size. Workaround: just move the canvas again a bit!
- *(Wayland, fractional scale)* Starting already maximized leaves a small offset on the right side. A manual unmaximize → maximize clears it
- Sometimes fails to launch and exits with code `-1073741819`. Relaunching works
- DPI changes are not applied at runtime
- Screen color profiles are untested and likely ignored by Affinity/Wine
- Expect random crashes and freezes. Stability has improved a lot, but it's not 100% reliable

# Building

This set of scripts have been crafted to run using an Arch Linux host. Even though it uses mainly the Steam Runtime (SteamRT) SDK docker container, there are stuff that happens in the host system. I really don't know why it works this way, but that's how Valve did. 

`./scripts/build.sh redist` is broken at this moment. `dist` and `wine` works. I use `dist` and a mixture of custom scripts + manual work to create builds for [run-affinity](https://github.com/Arecsu/run-affinity). This build process is pretty incomplete, so expect stuff to not even compile at all in your system. Or maybe not and you can do it! Arguably, for other devs, the `patches` here are the most important part of this project.

### Host dependencies

- `docker` — runs the SteamRT build container
- `git` — source fetching and patch application
- `make` — used to query the SteamRT image name from the Proton Makefile
- `rustup` with the stable x86_64 toolchain — mounted read-only into the container to override SteamRT's bundled cargo (1.68, too old for edition 2024 crates)

Everything else — compilers, mold, afdko, build tools — is provided by the SteamRT container. `ccache` is optional but recommended; if `~/.ccache` exists it will be used automatically.

> **Arch Linux only (for now).** SteamRT 4 is Debian-based, and the Proton build system assumes certain Debian multiarch conventions that Arch doesn't follow. The build script applies two workarounds inside the container: it creates `lib32`/`lib64` pkgconfig symlinks that Proton expects from Debian's multiarch layout, and wraps Debian-triplet compiler binaries (`i686-linux-gnu-gcc`) under the GNU-triplet names Proton looks for (`i686-pc-linux-gnu-gcc`). These may or may not be needed, or may need adjustment, on other distributions.

### 1. Fetch Sources

```bash
./scripts/build.sh --fetch
```

Clones proton-cachyos at the version pinned in `CACHYOS_TAG` and initializes all submodules.

### 2. Patch Wine

```bash
./scripts/build.sh --patch
```

Applies proton-cachyos patches and the Affinity-specific patches from `patches/` to the Wine source. Skips patches already applied (checked by commit subject), so it's safe to re-run.

### 3. Build

```bash
./scripts/build.sh dist
```

Builds the full Proton distribution inside the SteamRT container. Output lands in `.proton-src/build/dist/`.

## Development Commands

### Rebuild Wine only

```bash
./scripts/build.sh wine
```

Rebuilds only Wine and syncs the output into the existing dist tree. Much faster than a full rebuild when iterating on Wine patches.

### Package for redistribution (BROKEN)

```bash
./scripts/build.sh redist
```

Packages the built distribution into a `.tar.xz` archive ready to redistribute. The filename is derived from the proton-cachyos tag, e.g. `proton-affinity-11.0-20260429.tar.xz`.

Broken for some unknown reason regarding a python thing that I could not figure out.

### Reset Wine

```bash
./scripts/build.sh --wine-reset
```

Discards all commits and changes in the Wine source and returns it to the pinned submodule state. **Asks for confirmation. This destroys unpushed Wine work.**

### Sync to a new proton-cachyos version

```bash
./scripts/sync.sh            # auto-detects latest tag from upstream
./scripts/sync.sh <tag>      # use a specific tag
```

Updates `CACHYOS_TAG`, wipes `.proton-src`, and fetches the new base. It intentionally stops before patching, as a new proton-cachyos base will often require rebasing the Affinity patches. You might want to run `--patch` afterwards and see if they apply cleanly. Otherwise, conflicts must be resolved.

## Credits

- [Etaash Mathamsetty](https://github.com/Etaash-mathamsetty) — wine-em / wine-valve, the Wine fork proton-cachyos is based on
- [CachyOS](https://github.com/CachyOS/proton-cachyos) — proton-cachyos base
- [ElementalWarrior (James McDonnell)](https://gitlab.winehq.org/ElementalWarrior/wine) — wintypes hack and opencl patches
- [noahc3](https://github.com/noahc3/AffinityPluginLoader) — cubic Bézier subdivision algorithm (AffinityPluginLoader/WineFix)
- [Alexander Wilms](https://gitlab.winehq.org/wine/wine/-/merge_requests/10060) — XDG Desktop Portal file dialog integration (Wine MR !10060)
