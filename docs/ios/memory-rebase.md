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
