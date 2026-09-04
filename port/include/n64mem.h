/*
 * The N64 address window.
 *
 * The game treats a 32-bit N64 address as a dereferenceable pointer: the cart
 * sits at 0x10000000 and DRAM has two aliased views at 0x70000000 (s32-safe)
 * and 0x80000000 (KSEG0). Mapping those addresses literally works on desktop
 * but not on iOS, where __PAGEZERO covers everything below 0x100000000 and
 * vm_allocate returns KERN_INVALID_ADDRESS.
 *
 * So reserve one window at a 4 GiB-aligned base W and put every N64 address v
 * at W + v. Because W's low 32 bits are zero, truncating a host pointer back
 * to u32 still yields v, which is what the game's own pointer arithmetic
 * assumes (see loadAnimationFrame in src/game/model.c). The alignment is load
 * bearing, not a convenience.
 *
 * Windows keeps the old identity mapping. It works there and cannot be tested
 * from here.
 */
#ifndef PORT_N64MEM_H
#define PORT_N64MEM_H

/* No <stddef.h> / <stdint.h> here. Game TUs include this header, and pulling
 * the host C headers in ahead of <ultra64.h> silently changed something
 * layout-relevant in bondview2.c: the front end then crashed in
 * bgApplyDynamicCCRMLUT, nowhere near the change. The compiler's own type
 * macros need no header at all, so the hazard cannot come back. Same trick
 * port/shim/stddef.h uses on Linux. */
#if defined(_MSC_VER)
#include <stddef.h>
#include <stdint.h>
#define N64MEM_UINTPTR uintptr_t
#define N64MEM_U64     uint64_t
#define N64MEM_U32     uint32_t
#define N64MEM_SIZE    size_t
#else
#define N64MEM_UINTPTR __UINTPTR_TYPE__
#define N64MEM_U64     __UINT64_TYPE__
#define N64MEM_U32     __UINT32_TYPE__
#define N64MEM_SIZE    __SIZE_TYPE__
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Everything the game addresses, up to the top of the KSEG0 view. */
#define N64_WINDOW_SPAN 0x88000000ULL

/* Base of the window. Zero means identity mapping (Windows). */
extern N64MEM_UINTPTR g_n64Base;

/* Reserve the window. Call once, before anything maps into it. */
void n64memReserve(void);

/* Commit len bytes at N64 offset off, read/write. Returns the host pointer. */
void *n64memCommit(N64MEM_U64 off, N64MEM_SIZE len);

/* Make dstOff show the same pages as srcOff, which must already be committed. */
void *n64memAlias(N64MEM_U64 srcOff, N64MEM_U64 dstOff, N64MEM_SIZE len);

/* True if [p, p+len) lies inside the window. The DMA gate uses this. */
int n64memContains(N64MEM_UINTPTR p, N64MEM_SIZE len);

/* Read through an absolute cart symbol from romassets_<region>.s. Those
 * symbols hold N64 cart addresses, not host pointers, so taking one and
 * dereferencing it needs the window base put back first. Symbols used only as
 * a DMA source do not need this: piServiceDma converts them already. */
#define CART_HOSTPTR(type, sym) ((type)N64_TO_HOST((N64MEM_UINTPTR)&(sym)))

/* D177: the decomp's `(T *)((s32)ptr + byteOffset)` idiom is a no-op cast on
 * the N64's 32-bit pointers but truncates a 64-bit address on PC, so the write
 * lands somewhere else entirely. uintptr_t reproduces the arithmetic exactly
 * at either pointer width; layout-only, no behavior change. Used by the game
 * files that walk ROM-serialized records (stan.c, bondview_r.c). */
#define PORT_PTRADD(type, base, off) \
    ((type)((N64MEM_UINTPTR)(base) + (N64MEM_UINTPTR)(off)))

/* An N64 address as a host pointer, and back. */
#define N64_TO_HOST(v)   ((void *)(g_n64Base + (N64MEM_UINTPTR)(N64MEM_U32)(v)))
#define N64_FROM_HOST(p) ((N64MEM_U32)(N64MEM_UINTPTR)(p))

/* Like N64_TO_HOST, but a zero N64 address stays a null pointer. The window
 * base makes N64_TO_HOST(0) a valid-looking address, which silently turns a
 * list terminator or an unset field into a bogus object instead of a NULL the
 * caller can test. Use this wherever the N64 code compares the field against
 * NULL. */
#define N64_TO_HOST_OR_NULL(v) ((v) ? N64_TO_HOST(v) : (void *)0)

#ifdef __cplusplus
}
#endif

#endif
