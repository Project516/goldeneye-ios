# goldeneye-ios

An iOS port of GoldenEye 007 (N64), built from the decompilation.

Builds come out of GitHub Actions as unsigned IPAs and get sideloaded with
SideStore. No Mac is involved anywhere in the process.

## Status

Nothing is playable on iOS yet. Here is where things actually stand.

The desktop build runs. On Linux it boots, renders, and the front end works:
menu, mission select, briefing, mission start. Audio is not implemented on any
platform. There is a backlog of cosmetic rendering bugs in
`docs/dev/GRAPHICS-BACKLOG.md`.

The memory rebase is in and working on Linux. The game boots, loads and
renders through the intro and menus on the 4 GiB window, reaching the cast
screen in a one minute run. It is not stable indefinitely yet. See
`docs/ios/memory-rebase.md`.

Two things gated that work and both are settled, measured on a real device
rather than argued from documentation:

- iOS cannot map any address below `0x100000000`, which is where the desktop
  port places the cart image and both DRAM views. All three fail with
  `KERN_INVALID_ADDRESS`. The replacement is a single 4 GiB-aligned window
  where an N64 address `v` becomes `W + v`. That is verified working on device,
  including `vm_remap` aliasing for the KSEG0 mirror and thread stacks.
- The build needed GCC's `-fplan9-extensions`, which Clang does not have. All
  236 C translation units now compile under Clang using `-fms-extensions`.

Details and measurements: `docs/ios/memory-rebase.md` and `docs/ios/plan.html`.

## You need your own ROM

No ROM data ships in this repository, in any build, or in any artifact. You
supply your own copy.

Required: GoldenEye 007 (USA), sha1
`abe01e4aeb033b6c0836819f549c791b26cfde83`.

On iOS the ROM goes into the app's Documents folder through the Files app. On
desktop it goes in `data/`.

## Building on Linux

```sh
sudo apt install build-essential cmake python3 libsdl2-dev zlib1g-dev libgl1-mesa-dev

mkdir -p data
cp /path/to/GoldenEye.z64 data/ge007.ntsc-final.z64
python3 tools_pc/d43_emit.py ntsc-final
python3 tools_pc/d69_emit.py ntsc-final
python3 tools_pc/d88_emit.py ntsc-final --regen

cmake -S . -B build-pc -DROMID=ntsc-final
cmake --build build-pc -j"$(nproc)"
./build-pc/ge007.x86_64
```

Pass `-level_09` to boot straight into a level instead of the front end.

If your `gcc` is a ccache shim, pass `-DCMAKE_C_COMPILER=/usr/bin/gcc` and
`-DCMAKE_CXX_COMPILER=/usr/bin/g++`. The build derives the host `string.h`
path from the compiler's directory and a shim sends it somewhere wrong.

## Relationship to upstream

This is a hard fork of
[jkdansereau/goldeneye-pc-port](https://github.com/jkdansereau/goldeneye-pc-port),
which is itself built on the [GoldenEye
decompilation](https://gitlab.com/kholdfuzion/goldeneye_src). It was imported
as a single commit rather than a fork, does not track upstream, and will not
merge from it.

Some fixes here came from upstream's unmerged branches and are credited in the
commit that introduced them.

## Licence

AGPL-3.0, in `LICENSE`.

Upstream's port layer was MIT licensed by James Dansereau. MIT permits
sublicensing, so the combined work is distributed under AGPL-3.0 with that
original notice preserved in `LICENSE.MIT`. See `NOTICE` for what each licence
covers, and for the parts covered by neither.
