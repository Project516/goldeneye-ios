# Linux port, status and gap analysis

Session M-38 (2026-09-02). Goal-2 on the roadmap, after the Windows alpha /
release artifact. Started as a scoping and first-patch pass. Since then the
Linux build has actually been run: it boots, renders 300+ frames, the front
end works, and it exits cleanly. Audio is still not implemented. See "Linux
bring-up" below for the three bugs that had to be fixed to get there.

## Method

Read `build-pc.sh`, `CMakeLists.txt`, `docs/building.md`, and grepped
`port/src`, `port/fast3d`, `port/include` for Windows-only headers, Win32
APIs, and unguarded `_WIN32` branches. A local Qwen `triage` pass seeded the
hunt. Every claim below was re-checked against the real files, since the 27B
got two of three headline items wrong (see "Ruled out").

## What is already Linux-ready (verified by reading)

- `port/include/platform.h` sets `PLATFORM_LINUX` / `PLATFORM_MACOS` /
  `PLATFORM_WINDOWS` cleanly.
- `CMakeLists.txt` has `find_package(SDL2 REQUIRED)`, `find_package(ZLIB
  REQUIRED)`, and `else()` branches already present for the non-Windows case:
  `GL_LIBRARY = GL` (l.291), `EXTRA_LIBRARIES = stdc++ m dl pthread` (l.304),
  `elseif(UNIX)` platform block (l.86). `WIN32_EXECUTABLE` and the MinGW zlib
  fallback are correctly `if(WIN32)` / `if(MINGW)` guarded.
- `build-pc.sh` already documents the Linux apt deps
  (`cmake libsdl2-dev zlib1g-dev libgl1-mesa-dev`) and is a plain bash script,
  with no MSYS-isms in the executable body.
- `port/src/system.c`: `sysSleep()` has a `nanosleep()` `#else` branch
  (l.76-82); `<windows.h>` is `PLATFORM_WINDOWS`-guarded.
- `port/src/libultra.c`: the OS-thread kernel has a real pthreads branch next
  to the Win32 `_beginthreadex` one.
- `port/src/crash.c`: `MessageBoxW` / `SetThreadPriority` / `__debugbreak`
  are all `_WIN32`-guarded, with `PLATFORM_LINUX` counterparts.
- `port/src/video.c`: `GE_MKDIR` has both `_mkdir` and `mkdir(p,0777)`.
- No `__declspec`, `#pragma comment`, or hardcoded backslash-path or
  drive-letter usage anywhere in `port/`.

## Ruled out (Qwen triage false positives)

- ~~`system.c:75` `Sleep()` has no POSIX branch~~. It does (`nanosleep`).
- ~~CMake needs `else()` branches for zlib/pthread on Linux~~. Already there.

## The one real code gap, fixed this session (verification owed)

`port/src/romdata.c` has the fixed-address cart map (`0x10000000`, so absolute
ROM-asset symbols are live host pointers). It had a Windows-only
implementation (`VirtualAlloc`); the `#else` branch was a stub that logged
"not implemented on this platform" and fell straight to the heap-copy
fallback. In heap-copy mode, anything that dereferences a cart address
directly, not via `romdataGetRom()` or the PI shims, reads wrong memory. So
Linux would have run, if at all, in the same degraded mode Windows only hits
when `VirtualAlloc` loses the address race.

Change (M-38):
- Factored the post-map work (memcpy + `pcmodelsLoadSidecars` +
  `pccgLoadSidecars` + D55 RLE-header fixup) into `romdataFinishCartMap()`,
  shared by both paths so they cannot drift.
- The POSIX `#else` now does an anonymous `mmap((void*)CART_BASE, len,
  PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS|MAP_FIXED_NOREPLACE, -1, 0)`.
  `MAP_FIXED_NOREPLACE` (Linux 4.17+) fails rather than clobbering an existing
  mapping; where the macro is absent, the plain hint is advisory and the
  `at == CART_BASE` check catches a relocated result. On any failure it
  `munmap`s and falls through to the same heap-copy path as before.
- `romdataDestroy()` now `munmap`s on POSIX (tracked length in `mappedLen`).

## Linux bring-up (this session): boots, runs, exits clean

The build now runs end to end on Linux: it boots, renders 300+ frames, the
front end works, and it exits cleanly. Audio is still not implemented. Three
bugs had to be fixed to get here:

1. A `va_list` ABI bug in `_Printf`. On x86-64 SysV, `va_list` is passed as an
   array, so a by-value `va_list` parameter decayed to a pointer instead of
   copying the argument state, corrupting anything downstream that reused the
   list.
2. `stan.c`'s `tileStack[39]` was indexed past its end because the bail check
   was `cat >= 41`, two slots too late for a 39-entry array.
3. Ubuntu's gcc `-fstack-protector-strong` turned latent decomp overruns
   fatal, where MinGW's defaults had let them slide. The Linux build now
   compiles with `-fno-stack-protector`.

Owed verification, from the original plan, now mostly answered:
1. Compiles under GCC on Linux. Confirmed, `<sys/mman.h>` resolves cleanly,
   no decomp-include-path shadowing surprise.
2. Whether `mmap` actually lands at `0x10000000` on a stock ASLR Linux, since
   `0x10000000` (256 MB) is low but usually free. Still worth watching; if a
   kernel routinely refuses it, the fallback is linking the binary no-PIE or
   reserving the range via a linker script so the loader keeps it clear.
3. `-level_09` boots crash-free with the mapped path taken (check the log
   says "mapped at 0x10000000 (cart base)", not "using heap copy"). Confirmed
   for this session's run.
4. Whether the heap-copy fallback is actually survivable on Linux if step 2
   fails, which needs an audit for direct `0x1xxxxxxx` derefs outside the PI
   shims. Still open.

## Remaining Linux work after the romdata patch lands

| # | Item | Size | Note |
|---|------|------|------|
| 1 | Run the Ubuntu **`validate`** CI job, then upgrade it to a real **compile** job | S | `.github/workflows/ci.yml` already configures on Ubuntu; flipping it to `cmake --build` surfaces the real GCC-strictness gaps cheaply |
| 2 | First actual Linux runtime bring-up (`-level_09`) | M | done this session; a short tail of unguarded calls / struct-layout asserts (GCC vs MinGW) may still turn up on other levels |
| 3 | `docs/building.md`: promote Linux from "untested" to "supported" | S | now overdue, since the boot/render/exit run above already clears the bar |
| 4 | SDL2 / GL context creation on X11 + Wayland | M | fast3d is GL 3.3 core; the PD port runs on Linux, so the path is known-good |
| 5 | Package: an AppImage or tarball equivalent of `bundle-win.sh` | M | reuse `prepare-assets.py` verbatim, it is already OS-agnostic |

## Recommended next step

Land the romdata patch behind CI (item 1): turn the Ubuntu `validate` job
into a compile job in the same PR so "does it build on Linux" is answered by
the bots, then extend the runtime bring-up (audio, other levels) on a real
machine.
