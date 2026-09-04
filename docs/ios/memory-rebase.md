# Rebasing the N64 address space for iOS

## Why

The PC port maps the cart at `0x10000000` and two aliased DRAM views at
`0x70000000` and `0x80000000`. iOS covers everything below `0x100000000` with
`__PAGEZERO` and will not let a PIE binary give it up. Measured on device:
`vm_allocate` returns `KERN_INVALID_ADDRESS` and `mmap` returns `ENOMEM` for
all three.

## The scheme

Reserve one 4 GiB-aligned window `W` and resolve every N64 address `v` as
`W + v`. Because `W`'s low 32 bits are zero, truncating a host pointer to
`u32` still yields `v`, which is exactly the "physical offset" semantics the
game code assumes. That preserves `src/game/model.c:5876-5889`, which
truncates a real pointer, does arithmetic, and casts back.

Verified on device (iOS 26.6.1): window at `0x300000000`, cart and DRAM
commit, `vm_remap` aliases the KSEG0 view onto the same pages in both
directions, and a pthread runs on a stack committed inside the window with
`W + (u32)&local == &local`.

`W` must be chosen at runtime. iOS refused a 6 GB over-reserve but accepted a
specific 4 GiB-aligned base immediately, so walk candidates from
`0x300000000` upward rather than reserving a large span and carving it.

## The part that is not mechanical

Most address traffic already funnels through four symbols, so re-pointing
them moves 207 call sites at once:

| Symbol | Uses | Defined in |
| --- | --- | --- |
| `osVirtualToPhysical` | 131 | `port/src/libultra.c` |
| `OS_K0_TO_PHYSICAL` | 38 | `port/shim/PR/os.h` |
| `PHYS_TO_K0` / `OS_PHYSICAL_TO_K0` | 36 | `port/shim/PR/R4300.h` |
| `osPhysicalToVirtual` | 2 | `port/src/libultra.c` |

`seg_addr()` in `port/fast3d/gfx_pc.cpp:2627` absorbs display-list resolution
the same way.

The obstacle is `port/src/dram_syms.s`, which defines three symbols at
link-time absolute addresses so that `&cfb_16` is a live pointer with no game
code changes:

    cfb_16                  0x70000000
    _bssSegmentEnd          0x70050000
    animations_frame_buffer 0x707FFD30

**That trick cannot survive on arm64.** `ADRP` reaches +/-4 GB from the PC. With
the image near `0x104000000` and the window at `0x300000000`, the distance is
about 9.8 GB, so the references will not relocate. The symbols have to become
runtime values.

## How the three symbols convert

`cfb_16` is declared `extern u8 cfb_16[N][SZ]` (`src/fr.h:178`). Redeclaring
it as `u8 (*cfb_16)[SZ]` assigned at init keeps `cfb_16[i]` and `&cfb_16[0]`
compiling and meaning the same thing. Only bare `&cfb_16` changes meaning, at
three sites: `src/crash.c:272`, `src/fr.c:1031` and `src/fr.c:1112`, which
become plain `cfb_16`.

The real work is the static initializers, which need a link-time constant and
so must move to runtime assignment:

- `src/crash.c:272` — `g_StackPtrs2[] = { ..., &cfb_16 }`
- `src/game/initanitable.c:34-35` — two `&animations_frame_buffer` entries

`_bssSegmentEnd` is only read as `&_bssSegmentEnd` in `src/boss.c:263` to seed
the mempools, so it becomes a variable holding the window-relative address.

Counted usage: `cfb_16` 31 refs / 10 files, `_bssSegmentEnd` 11 / 6,
`animations_frame_buffer` 9 / 4.

## Highest risk

`piServiceDma`'s destination pointer (`port/src/libultra.c:888`) is a raw
`void *` with no conversion funnel, unlike every other path. An incomplete
audit of the 33 `romCopy()` callers leaves a wrong-pointer bug that corrupts
memory silently instead of crashing. Audit them all before trusting the
rebase.

`port/src/libultra.c:350` `portAllocLowStack` is a second sub-4 GB
dependency. Its `MAP_32BIT` branch is a no-op on Darwin, so stacks must be
committed inside the window instead.

## The cart side is cheaper, for a non-obvious reason

`port/src/romassets_<region>.s` defines **1685** absolute symbols covering
every obseg/ramrom/music blob, e.g.

    .global bg_silo_all_p_seg
    .set    bg_silo_all_p_seg, 0x10449450

At first glance these look like the same ADRP problem as `dram_syms.s`. They
are not, and the difference is what a reference compiles into:

- **Code** referencing an absolute symbol becomes `ADRP` + `ADD`, which reaches
  only +/-4 GB from the PC. That is what kills the three DRAM symbols.
- **Data** holding one, a pointer field in a static array, is just a 64-bit
  constant with a data relocation. No range limit, so it links fine on arm64.

Every one of the 1685 is consumed as data. `assets/obseg/obseg.h` declares them
`extern u8 name[]`, and the single consumer is the static table in
`assets/obseg/file_resource_table.inc.c`:

    {BG_SILO_ALL_P, "bg/bg_silo_all_p.seg", &bg_silo_all_p_seg},

which `src/game/ob.c:29` includes. No code dereferences these symbols directly.

So the addresses land in the binary as plain constants and only have to be
corrected once, at runtime. `obInit()` (`src/game/ob.c:120`) already walks the
whole table and already has a `#ifdef PORT` hook at the end calling
`pcmodelsPatchTable()` / `pccgPatchTable()`. Adding `W` to each `hw_address`
belongs in that same pass.

That means the cart rebase is one loop over an existing table, not 1685 edits.

## DMA destination audit

28 compiled call sites reach `piServiceDma`: 26 via `romCopy()` and 2 direct
`osPi*StartDma`. Of those, **22 are safe** (real allocations: `alHeapAlloc`,
`mempAllocBytesInBank`, genuine arrays and parameters).

**9 danger points across 7 locations** fabricate the destination by truncating
a real pointer to 32 bits, which works only while the identity mapping makes
addresses fit. Most dangerous first:

1. `src/game/model.c:5876-5894` — `loadAnimationFrame`, the known case.
2. `src/music.c:879/881`, `1073/1075`, `1267/1268` — `(t3 + (s32)ptr) - size`
   on `alHeapAlloc()` pointers, once per music track. Same mechanism as 1.
3. `src/game/front.c:6573` and `:6604` — `(s32)(ptr) + offset` stored in a
   `Gfx *`, feeding two independent DMA chains (`_fileNameLoadToAddr` and
   `langLoadToBank`).
4. `src/game/image_bank.c:245` — `((u32)p + 0xFFF) & 0xFFFFF000` truncates a
   real allocation. `pGlobalimagetable` is declared `s32 *`, so the field's
   type has to change, not just this line.
5. `src/game/title.c:399-400` and `:463-464` — file-scope `s32` variables
   holding N64 virtual addresses, passed straight to `romCopy`.

Two need review rather than a known fix: `src/init.c:132` depends on
`gen_romassets.py` emitting rebased values, and the `load_object_fill_header`
destination family has ~15 origins not fully traced.

`ob.c:179/241` are not among them. Both call `romCopy` with four arguments
against a three-parameter function, but this is already covered: the call
binds to `void romCopy();` in `port/include/pc_protos.h`, so there is no
implicit declaration, and an empty parameter list means the fourth argument
is simply discarded by the callee, the same as on MIPS. Only `:241` is
compiled either way, because `:179` sits under `#if !defined(LEFTOVERDEBUG)`
and the PC build defines `LEFTOVERDEBUG` (`CMakeLists.txt:151`).

### Do this before touching any of them

`dramHostAddrValid()` (`port/src/libultra.c:794-822`) is **`return 1;` on
POSIX** — it only validates on Windows. That absence is what makes these bugs
silent. Once the window exists there is a cheap exact test, namely whether the
destination lies inside `[W, W + span)`, so make it a real check on every
platform first. Every site above then fails loudly at its first DMA with the
offending pointer, instead of corrupting memory somewhere else entirely.

That turns the audit's residual risk, the sites nobody traced, into a crash
with an address rather than a heisenbug.

## Where the rebase got to

Done on Linux. The window is implemented in `port/src/n64mem.c` and the game
runs on it: a 180 second front-end run and a 90 second `-level_09` run both
complete with no crash and no rejected DMA target. That is the same standard
the port met before the rebase.

Working method, which is worth repeating rather than reading code: build, run,
symbolicate. The `dramHostAddrValid` gate names a bad DMA target with its
pointer, and `addr2line -f -C -s -e /tmp/build-pc/ge007.x86_64 0x<PC>` names
the crash site. Almost every bug was found this way in a few minutes each.

### The shape every bug took

A real pointer squeezed through a 32-bit slot. That worked while the identity
mapping kept addresses below 4 GiB and stops working the moment the window
moves them. Three variants, and it is worth knowing which you are looking at:

1. **A pointer stored in an `s32`/`u32` variable, field or parameter.** Fix by
   widening it. Examples: `memp.c` `mempStart`, `language.c` `g_LangBanks`,
   `title.c` `virtualaddress` and `barrelDisplayListPtr`, `boss.c`
   `rspReplyMsg`, `chr_b.c` `opcode`, `front.c`
   `display_aligned_white_text_to_screen`'s last two parameters.
2. **A pointer truncated mid-expression, then cast back.** Fix by keeping the
   arithmetic on the pointer. Examples: `music.c`'s three track loads,
   `image.c`'s alignment casts, `front.c`'s `ptr_logo_and_walletbond_DL`.
3. **A genuine N64 address held in 32 bits on purpose.** Do NOT widen these.
   The window base is 4 GiB-aligned precisely so they round-trip. Add the base
   at the dereference instead, which is what `N64_TO_HOST` is for. Examples:
   `animation_table_ptrs1/2`, the `unk34`/`unk38`/`unk64`/`unk68` bitstream
   fields, `PROMOTE`, `seg_addr`, `langGet`'s `output_slot`.

Telling 3 apart from 1 is the only judgement call. If the value is also used
as an offset, compared against another stored value, or written back into ROM
layout, it is case 3.

### Two that were not truncations

Worth recording because they cost the most time. `rzipGetSomething` was fixed
first in `src/game/decompress.c`, which `CMakeLists.txt` excludes in favour of
`port/src/rzdecomp.c`, so the fix was dead code and the symptom did not move.
Check which implementation actually compiles before believing a fix.

`gfx_tex_source_is_c_array` decided texture byte order from literal address
ranges (`0x10xxxxxx` cart, `0x70`-`0x90xxxxxx` DRAM). Nothing crashed; every
raw N64 stream simply fell through to the C-array branch and got byte-swapped.
The window makes the test both simpler and harder to get wrong: N64-derived
data is inside it, the exe image is not.

### Still open

Nothing known on Linux. Next is the iOS target itself: a CMake iOS toolchain,
an SDL2 iOS backend, a GLES3 or Metal renderer, touch controls, and the
Documents-folder ROM flow.

Not started: `obInit`'s `file_resource_table` `hw_address` pass. It has not
been needed, because those entries are only ever used as DMA sources and
`piServiceDma` converts them. Leave it alone unless something dereferences one
directly.

Windows is untouched and still identity-mapped. It will need the same sweep if
anyone wants it working again.

## iOS build bring-up

The iOS configure and build now run in CI on every push touching the build,
`port/`, `src/` or `include/` (`.github/workflows/ios-configure.yml`). It is
continue-on-error and reports the remaining errors grouped by kind, so the
next blocker is a fact rather than a guess. Xcode 26.6, iPhoneOS 26.5 SDK.

Cleared so far:

- CMake knows iOS. Every `APPLE` branch had assumed macOS, and the GCC search,
  deployment target, target-OS name and GL framework all needed splitting.
- SDL2 2.30.9 and zlib 1.3.1 build from source for arm64 via FetchContent. An
  iOS SDK has neither. SDL2 also supplies the UIKit app shell and `main()`.
- Host C-library headers resolve through the SDK on Apple. The old derivation
  (compiler dir + `../include`) landed in the Xcode toolchain dir, where
  `string.h` does not exist. The same fix covers a ccache shim on Linux.
- `_FORTIFY_SOURCE=0` on Apple. Darwin's `<string.h>` defines `strcpy` and
  friends as fortified macros, which `src/str.h` then redeclares as functions.
- The weak aliases are spelled a third way. Mach-O has no symbol aliases.

- Mach-O assembly for `romassets`. `gen_romassets.py --macho` emits
  `.section __DATA,__data` and underscores all 1685 symbols. The underscore is
  needed twice over: Mach-O mangles C symbols with one, and it treats a leading
  `L` as a local label, so every language-bank symbol (`LameE`, `Ltitle...`)
  was rejected as "non-local symbol required". That cleared 89 errors. The
  absolute-symbol scheme itself was never in question: these are consumed as
  data, and a data relocation against an absolute symbol is fine on arm64.

### It links

**2026-09-04: the iOS build succeeds and produces `GoldenEye.app` holding a
Mach-O 64-bit arm64 executable.** Verified by the last step of
`ios-configure.yml`, which requires that binary to exist, so the job can no
longer go green on a failed build.

What cleared the last of it, after the Mach-O assembly work:

- **The C++ include order**, which was the long pole. libc++ on Darwin
  hard-errors if `<cstddef>` does not get libc++'s own `<stddef.h>`, and the
  decomp's `include/` sat ahead of the C++ standard library on the path. The
  fix is `-idirafter` for the whole decomp include list in the C++ TUs.
  Putting libc++'s `c++/v1` first as a `-I` does not work, because clang drops
  a `-I` that duplicates a directory already on its system include list, so
  the flag simply vanished and the decomp's headers stayed in front. This was
  measured on CI with `c++/v1` printed first in the resolved list and
  `<cstddef>` still failing. Three earlier attempts failed by guessing where
  libc++ lived rather than asking the compiler; the toolchain step in the
  workflow now prints clang's own C++ include search list, so the next path
  question is answered from output.
- **A C++ target split.** `port_cxx` exists because per-source
  `COMPILE_OPTIONS` are emitted after the target's `HEADER_SEARCH_PATHS` under
  the Xcode generator, so a per-file include order cannot win there. Note that
  `set_target_properties(... INCLUDE_DIRECTORIES "")` does not clear the
  property, it sets a one-element list holding `""`, which then sits at the
  head of the include order.
- **`CMAKE_OSX_SYSROOT` is the SDK *name*** ("iphoneos") under the Xcode
  generator, not a path. Every string that concatenated it was silently
  producing nothing. `PORT_APPLE_SDK` resolves it once via
  `xcrun --show-sdk-path`.
- **The truncation class, enumerated rather than crashed into.** The 64-bit
  guards found by compiler diagnostics rather than by running, which is how
  the remaining pointer-width sites were closed.
- **Two symbols the link was still missing.** `crashDumpThreads` did not exist
  because `port/src/crash.c` was `#if PLATFORM_WINDOWS / #elif PLATFORM_LINUX`
  with nothing at the bottom; the branch is POSIX, so `platform.h` now defines
  `PLATFORM_POSIX` and crash.c keys off that. And
  `objectiveGetStatus_WEAK` came from `#pragma weak name = target`, an ELF
  directive with no Mach-O equivalent, so under `PORT` it is a real forwarding
  function.

### The current blocker

**The renderer.** `port/fast3d/gfx_opengl.cpp` targets desktop GL and iOS has
none, so expect the app to launch and fail at renderer init.

It is a much smaller job than the doc used to imply, because the ES path
mostly already exists. An audit of every `gl*` entry point `gfx_opengl.cpp`
calls, against GLES 3.0:

- All but three are GLES 2 or 3 core, including the ones that look risky:
  `glBlitFramebuffer`, `glRenderbufferStorageMultisample`, `glReadBuffer`,
  `glGenVertexArrays`/`glBindVertexArray`, `glPolygonOffset`.
- The three that are not are already handled at runtime.
  `glDepthRange` sits behind `if (glDepthRangef)`, both
  `glDebugMessageControl` and `glDebugMessageCallback` behind `!= NULL`, and
  `GL_MIRROR_CLAMP_TO_EDGE` is downgraded to `GL_MIRRORED_REPEAT` when
  unsupported.
- The shader generator has a complete ES path: a `gl_es` flag, a
  `precision mediump float;` line in both stages, `in`/`out` versus
  `attribute`/`varying`, and `texture()` versus `texture2D()`.

So the remaining unknowns are narrow: whether `glad`, a desktop GL loader,
behaves against an ES context, and whether the GLSL that comes out actually
compiles on a real driver. `gfx_sdl2.cpp` now asks for ES 3.0 and only ES 3.0
on iOS, with no fallback, so a context problem says so instead of handing back
an ES 2 context the GLSL 130 path cannot use.

Do not guess further. The app builds and installs now, so get a launch and
read what it actually says.

## A regression worth remembering

`ffb9b76` moved the thread stacks from window offset `0x20000000` to
`0x30000000` and broke the front end. It is reverted.

The move was defensive and the reasoning behind it was simply wrong. It said
stacks must avoid `0x20000000` because the Linux image links there, but that
conflates two address spaces: the image sits at `0x20000000` in the host's own
space, not at window offset `0x20000000`. Nothing collided.

`0x30000000` is actively worse. `seg_addr` treats an odd `w1` as a segmented
address and takes the segment index from bits 24-27, so a truncated stack
pointer at `0x3xxxxxxx` selects `segmentPointers[3]` and returns garbage. The
symptom was `gfx_run_dl` faulting on a nested `G_DL` target.

Two lessons, both mine:

- The change was committed on the strength of a `-level_09` run, which skips
  the front end. The front-end run that passed predated it. Verify the path a
  change can plausibly affect, not the path that happens to be handy.
- It was a fix for a problem that had never been observed, reasoned from a
  comment rather than from a failure. The comment was about the image base and
  did not apply.

## Original regression note, kept for the bisect recipe

The Linux build crashes on startup as of `b3c5402`. A clean build reaches one
VI post and dies in `gfx_run_dl` (`port/fast3d/gfx_pc.cpp:2679`, the
`cmd->words.w0` read at the top of the command loop), with the same symptom
under both `/usr/bin/gcc` and the ccache shim, so it is the tree and not the
toolchain.

Two things narrow this, both learned after the note above was written.

**The two suspects are cleared.** `PORT_REAL_ZLIB_H` resolves to
`/usr/include/zlib.h` and `PORT_HOST_STDDEF_H` to the compiler's own
`stddef.h`, both correct, so `18fe877` is not it. And the `_GNU_SOURCE` that
`6bd9b27` removed was already dead: `dram.c` gained `#include <ultra64.h>`
above it during the symbol-binding work, so it no longer preceded the system
headers and had stopped doing anything. Deleting the stale config
(`data/ge007.ini`) changes nothing either.

**`ffb9b76` itself is now the prime suspect, because the verification after it
was too narrow.** That commit moved the thread stacks from window offset
`0x20000000` to `0x30000000`, and the only run afterwards was `-level_09`,
which skips the front end. The 180 second front-end run that passed was from
*before* it. So the front end may have been broken by that commit and simply
never exercised. Test `ffb9b76` with a plain front-end run first; if it fails
there, the stack move is the culprit and the region needs choosing more
carefully against what `seg_addr` decodes.

The crash detail supports something address-shaped rather than a header
problem: `gfx_run_dl` faults reading `cmd->words.w0` after being called
*recursively* from the `G_DL` case, so a nested display-list address resolved
to something unmapped. That is `seg_addr` returning a bad pointer, not a
compile-time issue.

Original note, kept because the recipe is still the right one:

- `6bd9b27` dropped `#define _GNU_SOURCE` from `port/src/dram.c`. Should be
  inert, since `memfd_create` moved to `n64mem.c`, but glibc gates some
  `mman.h` constants on feature-test macros, so check `MAP_ANONYMOUS` is still
  what it was.
- `18fe877` changed how the host C-library headers are resolved. It reports
  the same three paths as before on this machine, but confirm
  `PORT_HOST_STDDEF_H` and `PORT_REAL_ZLIB_H` still resolve: those still use
  `_PORT_GCC_DIR`, whose definition moved in that commit.

The other commits are Apple-only (`_FORTIFY_SOURCE`, the alias macros) or
touch CI and `gen_romassets.py`'s `--macho` path, which the ELF output does
not take.

To bisect without disturbing the tree:

    git worktree add /tmp/wt <sha>
    cmake -S /tmp/wt -B /tmp/wtb -DROMID=ntsc-final
    cmake --build /tmp/wtb -j"$(nproc)"
    DISPLAY=:0 timeout 45 /tmp/wtb/ge007.x86_64

`data/` is at the repo root and is found relative to the binary, so a worktree
build may need `data/` symlinked next to it.
