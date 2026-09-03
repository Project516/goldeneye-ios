# goldeneye-ios

## What this is

An iOS port of GoldenEye 007 (N64), built on the existing decompilation and PC
port work. Ships as an unsigned IPA sideloaded with SideStore. No Mac is
involved: every Apple-toolchain build happens on GitHub Actions macOS runners.

## Direction

Optimize for, in order:

1. **Running at all on a real iPhone.** Correctness and boot-to-gameplay beat
   features, resolution, and polish.
2. **A platform layer that survives the game underneath changing.** The iOS
   layer (renderer backend, touch input, filesystem, app shell) should stay
   game-agnostic within the Rare N64 FPS engine family, so it can move between
   the GoldenEye and Perfect Dark port trees.
3. **Low memory and steady frame pacing.** Phones throttle and get killed for
   memory. A stable 30 fps beats a stuttering 60.

Explicit non-goals: App Store distribution, jailbreak support, multiplayer
netcode, and shipping anything ROM-derived.

## Hard rules

- **No ROM, and nothing extracted from a ROM, ever enters this repo or an
  artifact.** The user supplies `GoldenEye.z64` on-device through the Files
  app. `.gitignore` covers `*.z64`/`assets/`; do not weaken it.
- **No GitHub Releases.** CI artifacts only, so builds are not distributed.
  The repo is public for free macOS runner minutes, not to hand out builds.
- macOS runners are the slow, contended ones. Keep `timeout-minutes` set and
  do not add push triggers that rebuild on unrelated changes.

## Glossary

- **decomp** - `goldeneye_src`, the matching decompilation that rebuilds a
  byte-identical N64 ROM. Source of truth for game logic.
- **port layer** - the `port/` directory added on top of a decomp to run its
  game code on a host OS, replacing libultra and the RSP/RDP.
- **fast3d** - the N64 display-list interpreter (`gfx_pc.cpp`) that turns RSP
  command streams into modern draw calls. Shared lineage across sm64-port,
  Perfect Dark PC, and the GoldenEye PC port.
- **rendering backend** - a concrete implementation of `gfx_rendering_api.h`
  (currently only desktop GL). The iOS one is new work.
- **DRAM views** - the port's two aliased mappings of N64 working RAM at
  `0x70000000` and `0x80000000`, plus the cart image at `0x10000000`. See
  `port/src/dram.c`. Whether iOS permits these is the project's gating risk.
- **__PAGEZERO** - the unmapped guard region at the bottom of a Mach-O address
  space, 4 GB by default on arm64, which covers all three DRAM/cart addresses.
- **probe** - `probe/`, the Stage 0 throwaway app that answers the __PAGEZERO
  question on real hardware.

## Reference checkouts

`code/` holds read-only upstream clones and is gitignored. Do not edit them,
and do not add them as submodules.

| Path | Role |
| --- | --- |
| `code/goldeneye_src` | the decomp; our ROM's sha1 matches its US target |
| `code/goldeneye-pc-port` | the GoldenEye port layer we intend to build on |
| `code/perfect_dark_pc` | mature, arm64-clean port of the sibling engine |
| `code/sm64coopdx-ios` | the iOS packaging and touch-control template |
| `code/SCInsta` | unsigned-IPA CI patterns |
