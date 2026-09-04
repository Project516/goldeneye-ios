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

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Everything the game addresses, up to the top of the KSEG0 view. */
#define N64_WINDOW_SPAN 0x88000000ULL

/* Base of the window. Zero means identity mapping (Windows). */
extern uintptr_t g_n64Base;

/* Reserve the window. Call once, before anything maps into it. */
void n64memReserve(void);

/* Commit len bytes at N64 offset off, read/write. Returns the host pointer. */
void *n64memCommit(uint64_t off, size_t len);

/* Make dstOff show the same pages as srcOff, which must already be committed. */
void *n64memAlias(uint64_t srcOff, uint64_t dstOff, size_t len);

/* True if [p, p+len) lies inside the window. The DMA gate uses this. */
int n64memContains(uintptr_t p, size_t len);

/* An N64 address as a host pointer, and back. */
#define N64_TO_HOST(v)   ((void *)(g_n64Base + (uintptr_t)(uint32_t)(v)))
#define N64_FROM_HOST(p) ((uint32_t)(uintptr_t)(p))

#ifdef __cplusplus
}
#endif

#endif
