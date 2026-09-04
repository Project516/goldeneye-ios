/*
 * dram.c — a slice of N64 "DRAM" in host memory, mapped twice.
 *
 * GE's game code mixes two address conventions that cannot both hold on an
 * x64 host with a single mapping:
 *
 *   1. Pointers that pass through s32 (e.g. mempCheckMemflagTokens(s32, s32)
 *      in src/memp.c). Any address with bit 31 set sign-extends to an
 *      invalid 0xffffffffXXXXXXXX pointer when stored back into a u8*.
 *      => the game's working RAM must live BELOW 0x80000000.
 *
 *   2. "Physical" addresses that the game ORs with 0x80000000 to make them
 *      dereferenceable (e.g. `texnum = *((u16 *)(temp.word | 0x80000000))`
 *      in src/game/bg.c, where temp.word is a GBI w1 value produced by
 *      OS_K0_TO_PHYSICAL). => a KSEG0 view at 0x80000000 must exist and
 *      mirror the working RAM.
 *
 * The port therefore maps ONE 8 MB section at two addresses:
 *
 *   V1 @ 0x70000000  "virtual" view — s32-safe; ALL game RAM symbols live
 *                     here (cfb_16, _bssSegmentEnd/mempool start, tlbBlock/
 *                     mempool end). Mempool pointers etc. are 0x70xxxxxx:
 *                     positive as s32, safe through every 32-bit path.
 *   V2 @ 0x80000000  KSEG0 view — byte-identical mirror of V1 (same section
 *                     backing), for code that rebuilds pointers with
 *                     `offset | 0x80000000`.
 *
 * The port-side header shims (port/shim/PR/R4300.h, port/shim/PR/os.h) make
 * the conversion macros consistent with this layout:
 *   PHYS_TO_K0(x)         = x                          (identity)
 *   OS_K0_TO_PHYSICAL(x)  = (u32)((char*)x - V1_BASE)  (small offset)
 * so GBI w1 words carry small offsets that fast3d's seg_addr() resolves by
 * adding 0x80000000 (landing in V2, same data), and osVirtualToPhysical(x)
 * stays the identity (V1 addresses are already live host pointers < 4 GB).
 *
 * Layout (NTSC US .stacks sits at 0x803AB400, MAPPING_TABLE_COUNT=93 pages,
 * so the N64 tlb block is 0x803AB400 - 93*0x2000 = 0x802F4400 — kept as the
 * mempool end for fidelity):
 *
 *   +0x000000  cfb_16            (2 x 320x240x2 = 0x4B000, from src/cfb.c)
 *   +0x050000  _bssSegmentEnd    -> mempool start (boss.c:217)
 *   ...            game heap (mempools / dyn / audio buffers)
 *   +0x2F4400  tlb block         -> mempool end (tlbmanageGetTlbAllocatedBlock)
 *   ...            free
 *   -0x0002D0  animations_frame_buffer (0x2D0, D59; dram_syms.s absolute sym)
 *   +0x800000  end of region (8 MB, like an 8-MB-RAM N64)
 */

#include <ultra64.h>
#include <fr.h>

#include "platform.h"
#include "system.h"
#include "n64mem.h"

#if defined(PLATFORM_WINDOWS)
#include <windows.h>
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

#define DRAM_V1_BASE   0x70000000UL /* s32-safe "virtual" view */
#define DRAM_K0_BASE   0x80000000UL /* KSEG0 mirror view */
#define DRAM_SIZE      0x00800000UL /* 8 MB */

/*
 * Objects the game reaches by name that have to live in DRAM rather than in
 * host BSS. These were link-time absolute symbols (port/src/dram_syms.s);
 * they are ordinary pointers now, bound by dramBindSymbols() once the region
 * exists, because arm64 cannot reference an absolute symbol that sits further
 * than ADRP's +/-4 GB from the image. Offsets are unchanged.
 *
 * cfb_16       the two 320x240x16 framebuffers, replacing src/cfb.c.
 * _bssSegmentEnd  where boss.c starts the mempools.
 * animations_frame_buffer  animation scratch (D59); loadAnimationFrame()
 *              addresses it through s32 fields, so it must stay somewhere a
 *              u32 truncation can recover.
 */
#define CFB16_OFS      0x00000000UL
#define BSSEND_OFS     0x00050000UL
#define ANIMBUF_OFS    0x007FFD30UL

u8 (*cfb_16)[SCREEN_WIDTH * SCREEN_HEIGHT * 2];
u32 *_bssSegmentEnd;
char *animations_frame_buffer;

static void dramBindSymbols(void *v1)
{
    char *base = (char *)v1;
    cfb_16 = (u8 (*)[SCREEN_WIDTH * SCREEN_HEIGHT * 2])(base + CFB16_OFS);
    _bssSegmentEnd = (u32 *)(base + BSSEND_OFS);
    animations_frame_buffer = base + ANIMBUF_OFS;
}

void *dramReserve(void)
{
#if defined(PLATFORM_WINDOWS)
    /* One anonymous section, two views at fixed addresses. */
    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(sa);
    sa.lpSecurityDescriptor = NULL;
    sa.bInheritHandle = FALSE;

    HANDLE hSec = CreateFileMappingW(INVALID_HANDLE_VALUE, &sa, PAGE_READWRITE,
                                     (DWORD)(DRAM_SIZE >> 32),
                                     (DWORD)(DRAM_SIZE & 0xFFFFFFFF), NULL);
    if (!hSec) {
        sysFatalError("dram: CreateFileMapping failed (%lu)", GetLastError());
    }

    void *v1 = MapViewOfFileEx(hSec, FILE_MAP_ALL_ACCESS, 0, 0, DRAM_SIZE,
                               (void *)DRAM_V1_BASE);
    if (v1 != (void *)DRAM_V1_BASE) {
        sysFatalError("dram: could not map DRAM at %p (err %lu)",
                      (void *)DRAM_V1_BASE, GetLastError());
    }

    void *v2 = MapViewOfFileEx(hSec, FILE_MAP_ALL_ACCESS, 0, 0, DRAM_SIZE,
                               (void *)DRAM_K0_BASE);
    if (v2 != (void *)DRAM_K0_BASE) {
        sysFatalError("dram: could not map KSEG0 mirror at %p (err %lu)",
                      (void *)DRAM_K0_BASE, GetLastError());
    }

    /* Sanity: the views must alias the same backing store. */
    ((volatile char *)v1)[0] = 0x5A;
    if (((volatile char *)v2)[0] != 0x5A) {
        sysFatalError("dram: V1/V2 views do not share a backing store");
    }
    ((volatile char *)v1)[0] = 0;

    CloseHandle(hSec);
    dramBindSymbols(v1);
    return v1;
#else
    /* Inside the window: commit V1, then alias the KSEG0 view onto the same
     * pages. n64memAlias proves the sharing before returning. */
    void *v1 = n64memCommit(DRAM_V1_BASE, DRAM_SIZE);
    n64memAlias(DRAM_V1_BASE, DRAM_K0_BASE, DRAM_SIZE);

    dramBindSymbols(v1);
    return v1;
#endif
}
