# Contributing

Thanks for your interest. This is a small hobby project, an iOS port of
GoldenEye 007. It was seeded from
[goldeneye-pc-port](https://github.com/jkdansereau/goldeneye-pc-port), but it
is a hard fork. It does not track that project and will not merge changes
from it, so a pull request meant for upstream belongs there, not here. Issues
and pull requests about this fork's iOS work are welcome, but please read the
ground rules first. They are what keep the port faithful to the original
game.

## Ground rules

1. **The decompilation is not modified for the port.** Everything under `src/`
   and `include/` is compiled unmodified. `Makefile`, `tools/`, `rsp/`, `ld/`
   belong to the N64 build and are never touched for port work. If port code
   seems to need a behavioural change in the game, the fix belongs in `port/`.

2. **Narrow ABI exception.** The 32→64-bit transition forces a small class of
   mechanical, semantics-preserving edits to ROM-serialized structs (storing an
   embedded 32-bit pointer as `u32` and casting at the use site). These are
   allowed, must be guarded with `#ifdef PORT`, must change no behaviour, and
   must be documented. See `docs/porting-notes.md` for the catalogue of
   patterns.

3. **Region macros mirror the Makefile.** `CMakeLists.txt` `REGION_DEFS` must
   match the N64 `Makefile`'s per-region macro set exactly.

4. **Verify before you push.** A build-affecting change needs, at minimum, a
   clean configure and build for `ntsc-final` and a crash-free run of one
   level (`./build-pc/ge007.x86_64 -level_09`) on the Linux build. Changes
   under `probe/` or the memory-mapping code follow `docs/ios/AGENTS.md`
   instead, and are checked against the `probe-ios` workflow.

## Style

- C/C++ formatting follows `.clang-format` and `.editorconfig` in the repo
  root. Match the surrounding code.
- Port-layer code is plain C11 / C++17, SDL2 + OpenGL, no extra dependencies.
- Keep commits focused and describe why, not just what.

## Where to look

- `docs/internals.md`, for how the port is structured.
- `docs/porting-notes.md`, for the recurring bug classes. Check here before
  debugging a crash; you are likely looking at a known pattern.
- `docs/ios/AGENTS.md` and `docs/ios/plan.html`, for the iOS memory rebase.
- `docs/dev/`, for the full finding log and per-level status.
