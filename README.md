# goldeneye-ios

An in-progress iOS port of GoldenEye 007 (N64), built on the
[decompilation](https://gitlab.com/kholdfuzion/goldeneye_src) and the
[PC port](https://github.com/jkdansereau/goldeneye-pc-port).

Builds are produced as unsigned IPAs by GitHub Actions and sideloaded with
SideStore. There is no Mac in the loop.

## Status

**Stage 0.** Nothing is playable. The current work is a throwaway probe app
that answers one question on real hardware: can a sideloaded iOS app map the
fixed low addresses the PC port depends on? See `docs/plan.html`.

## You need your own ROM

No ROM data is included here, in the build, or in any artifact, and none will
be. The app reads a `GoldenEye.z64` that you place in its Documents folder
through the Files app.

Supported: GoldenEye 007 (USA), sha1 `abe01e4aeb033b6c0836819f549c791b26cfde83`.

## Building

Everything Apple-toolchain runs in CI. To build the probe locally on a Mac:

```sh
cmake -S probe -B build-ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build-ios --config Release -- CODE_SIGNING_ALLOWED=NO
```

## Licence

The port layer here is ours. The decomp and PC port code it builds on carry
their own terms. No game assets are distributed.
