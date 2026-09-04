/*
 * The N64 address window. See port/include/n64mem.h for why it exists.
 */
#include "platform.h"
#include "system.h"
#include "n64mem.h"

#include <string.h>

#if defined(PLATFORM_WINDOWS)
#include <windows.h>
#else
#define _GNU_SOURCE
#include <sys/mman.h>
#include <unistd.h>
#include <errno.h>
#endif

#if defined(PLATFORM_MACOS) || defined(PLATFORM_IOS)
#include <mach/mach.h>
#include <mach/vm_map.h>
#endif

uintptr_t g_n64Base = 0;

#if !defined(PLATFORM_WINDOWS)
/* Walk 4 GiB-aligned candidates rather than over-reserving and trimming.
 * Measured on iOS 26.6.1: a 6 GB PROT_NONE reservation is refused with ENOMEM,
 * while a fixed base at 0x300000000 is accepted immediately. */
#define WINDOW_FIRST_BASE 0x300000000ULL
#define WINDOW_LAST_BASE  0x1000000000ULL
#define WINDOW_ALIGN      0x100000000ULL
#endif

void n64memReserve(void)
{
#if defined(PLATFORM_WINDOWS)
    /* Identity mapping, as before. */
    g_n64Base = 0;
#else
    for (uint64_t base = WINDOW_FIRST_BASE; base <= WINDOW_LAST_BASE;
         base += WINDOW_ALIGN) {
        void *p = mmap((void *)(uintptr_t)base, (size_t)N64_WINDOW_SPAN,
                       PROT_NONE,
                       MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED,
                       -1, 0);
        if (p != MAP_FAILED && (uint64_t)(uintptr_t)p == base) {
            g_n64Base = (uintptr_t)base;
            sysLogPrintf(LOG_INFO, "n64mem: window at 0x%llx (%.2f GB reserved)\n",
                         (unsigned long long)base,
                         (double)N64_WINDOW_SPAN / 1073741824.0);
            return;
        }
        if (p != MAP_FAILED) {
            munmap(p, (size_t)N64_WINDOW_SPAN);
        }
    }
    sysFatalError("n64mem: no 4 GiB-aligned window available");
#endif
}

int n64memContains(uintptr_t p, size_t len)
{
    if (p < g_n64Base) {
        return 0;
    }
    uint64_t off = (uint64_t)(p - g_n64Base);
    return off < N64_WINDOW_SPAN && (N64_WINDOW_SPAN - off) >= (uint64_t)len;
}

void *n64memCommit(uint64_t off, size_t len)
{
    void *want = (void *)(g_n64Base + (uintptr_t)off);
#if defined(PLATFORM_WINDOWS)
    void *got = VirtualAlloc(want, len, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (got != want) {
        sysFatalError("n64mem: commit at %p failed (%lu)", want, GetLastError());
    }
#else
    void *got = mmap(want, len, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (got == MAP_FAILED || got != want) {
        sysFatalError("n64mem: commit at %p failed (errno %d)", want, errno);
    }
#endif
    return got;
}

void *n64memAlias(uint64_t srcOff, uint64_t dstOff, size_t len)
{
    void *src = (void *)(g_n64Base + (uintptr_t)srcOff);
    void *dst = (void *)(g_n64Base + (uintptr_t)dstOff);

#if defined(PLATFORM_MACOS) || defined(PLATFORM_IOS)
    /* Darwin has no memfd. vm_remap shares the pages instead. */
    vm_address_t target = (vm_address_t)(uintptr_t)dst;
    vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
    kern_return_t kr = vm_remap(mach_task_self(), &target, len, 0,
                                VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                mach_task_self(), (vm_address_t)(uintptr_t)src,
                                FALSE, &cur, &max, VM_INHERIT_SHARE);
    if (kr != KERN_SUCCESS || (uintptr_t)target != (uintptr_t)dst) {
        sysFatalError("n64mem: vm_remap %p -> %p failed (kr %d)", src, dst, kr);
    }
#elif defined(PLATFORM_WINDOWS)
    sysFatalError("n64mem: alias unsupported here; dram.c maps its own views");
#else
    /* One memfd mapped twice gives two views of one backing store. */
    int fd = memfd_create("ge007_dram", 0);
    if (fd < 0) {
        sysFatalError("n64mem: memfd_create failed");
    }
    if (ftruncate(fd, (off_t)len) != 0) {
        close(fd);
        sysFatalError("n64mem: ftruncate failed");
    }
    void *a = mmap(src, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    void *b = mmap(dst, len, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    close(fd);
    if (a != src || b != dst) {
        sysFatalError("n64mem: could not map both DRAM views");
    }
#endif

    /* Prove they really share, in both directions, before anyone relies on it. */
    ((volatile char *)src)[0] = 0x5A;
    if (((volatile char *)dst)[0] != 0x5A) {
        sysFatalError("n64mem: views do not share a backing store");
    }
    ((volatile char *)dst)[1] = 0xA5;
    if (((volatile char *)src)[1] != (char)0xA5) {
        sysFatalError("n64mem: alias is one-way");
    }
    ((volatile char *)src)[0] = 0;
    ((volatile char *)src)[1] = 0;
    return src;
}
