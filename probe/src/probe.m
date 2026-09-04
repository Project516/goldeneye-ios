/*
 * Address-space probe for the GoldenEye iOS port.
 *
 * goldeneye-pc-port requires three fixed mappings that all sit below the 4 GB
 * line: the cart image at 0x10000000 and the two DRAM views at 0x70000000 and
 * 0x80000000 (port/src/romdata.c, port/src/dram.c). On arm64 Mach-O the whole
 * low 4 GB is covered by __PAGEZERO, and suite A confirms on device that those
 * addresses are unreachable.
 *
 * Suite B tests the replacement: reserve one 4 GB-aligned window wherever the
 * kernel will give us one, and treat every N64 address as an offset into it, so
 * W + v works for any 32-bit v and the game's `| 0x80000000` arithmetic still
 * round-trips in the low 32 bits. It also checks that the two DRAM views can be
 * aliased onto the same pages with vm_remap, which is what dram.c needs and
 * what it uses a memfd for on Linux.
 *
 * Results are shown on screen and written to Documents/probe-report.txt so they
 * can be pulled off the device with the Files app.
 */

#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <mach-o/dyld.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>

/* The three addresses the port hardcodes, with the sizes it actually asks for. */
#define CART_BASE     0x10000000ULL   /* romdata.c: the .z64 image        */
#define DRAM_V1_BASE  0x70000000ULL   /* dram.c: s32-safe "virtual" view  */
#define DRAM_K0_BASE  0x80000000ULL   /* dram.c: KSEG0 mirror             */

#define ROM_SIZE   (12u * 1024u * 1024u)
#define DRAM_SIZE  (8u * 1024u * 1024u)

/* The window has to span every address the game forms, so up to the top of the
 * KSEG0 view. Only the sub-ranges actually used get committed. */
#define WINDOW_ALIGN  0x100000000ULL              /* 4 GB */
#define WINDOW_SPAN   (DRAM_K0_BASE + DRAM_SIZE)  /* ~2.01 GB */

static void line(NSMutableString *out, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
static void line(NSMutableString *out, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    [out appendString:s];
    [out appendString:@"\n"];
}

/*
 * vm_allocate with VM_FLAGS_FIXED fails cleanly when the range is
 * unavailable instead of clobbering whatever is already mapped, so it is the
 * safe way to ask "is this address mine to take?".
 */
static BOOL probeMach(NSMutableString *out, uint64_t addr, size_t len) {
    vm_address_t a = (vm_address_t)addr;
    kern_return_t kr = vm_allocate(mach_task_self(), &a, len, VM_FLAGS_FIXED);
    if (kr == KERN_SUCCESS) {
        BOOL exact = (a == addr);
        /* Touch the first and last page: reserving is not the same as usable. */
        volatile uint8_t *p = (volatile uint8_t *)(uintptr_t)a;
        p[0] = 0x5A;
        p[len - 1] = 0xA5;
        BOOL readback = (p[0] == 0x5A && p[len - 1] == 0xA5);
        vm_deallocate(mach_task_self(), a, len);
        line(out, @"  vm_allocate  OK    got 0x%llx%@ rw=%@",
             (unsigned long long)a,
             exact ? @" (exact)" : @" (MOVED)",
             readback ? @"yes" : @"NO");
        return exact && readback;
    }
    line(out, @"  vm_allocate  FAIL  kr=%d (%s)", kr, mach_error_string(kr));
    return NO;
}

static BOOL probeMmap(NSMutableString *out, uint64_t addr, size_t len) {
    void *p = mmap((void *)(uintptr_t)addr, len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) {
        line(out, @"  mmap MAP_FIXED    FAIL  errno=%d (%s)", errno, strerror(errno));
        return NO;
    }
    BOOL exact = ((uint64_t)(uintptr_t)p == addr);
    munmap(p, len);
    line(out, @"  mmap MAP_FIXED    OK    got 0x%llx%@",
         (unsigned long long)(uintptr_t)p, exact ? @" (exact)" : @" (MOVED)");
    return exact;
}

static BOOL probeRegion(NSMutableString *out, const char *label, uint64_t addr, size_t len) {
    line(out, @"%s @ 0x%llx (%zu MB)", label, (unsigned long long)addr, len / (1024 * 1024));
    BOOL a = probeMach(out, addr, len);
    BOOL b = probeMmap(out, addr, len);
    line(out, @"  => %@", (a && b) ? @"USABLE" : @"NOT USABLE");
    line(out, @"");
    return a && b;
}

/* The iOS SDK does not declare getsegbynamefromheader_64, so walk the load
 * commands of the main image and read __PAGEZERO's vmsize directly. */
static NSString *pagezeroSize(void) {
    const struct mach_header_64 *hdr =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!hdr) return @"(no image)";

    const uint8_t *cmd = (const uint8_t *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cmd;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc =
                (const struct segment_command_64 *)cmd;
            if (strncmp(sc->segname, "__PAGEZERO", sizeof(sc->segname)) == 0) {
                return [NSString stringWithFormat:@"0x%llx", sc->vmsize];
            }
        }
        cmd += lc->cmdsize;
    }
    return @"(absent)";
}


/* ---- suite B: one 4 GB-aligned window, N64 address = W + v ---------------- */

/* Over-reserve PROT_NONE, then trim back to a 4 GB boundary. Costs address
 * space, not memory. Returns 0 if the kernel will not hand out that much VA. */
static uint64_t reserveWindowByTrimming(NSMutableString *out) {
    size_t total = (size_t)(WINDOW_SPAN + WINDOW_ALIGN);
    void *raw = mmap(NULL, total, PROT_NONE,
                     MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (raw == MAP_FAILED) {
        line(out, @"  reserve %.2f GB   FAIL  errno=%d (%s)",
             total / 1073741824.0, errno, strerror(errno));
        return 0;
    }

    uint64_t rawAddr = (uint64_t)(uintptr_t)raw;
    uint64_t base = (rawAddr + WINDOW_ALIGN - 1) & ~(WINDOW_ALIGN - 1);

    if (base > rawAddr) munmap(raw, (size_t)(base - rawAddr));
    uint64_t tail = base + WINDOW_SPAN;
    uint64_t rawEnd = rawAddr + total;
    if (rawEnd > tail) munmap((void *)(uintptr_t)tail, (size_t)(rawEnd - tail));

    line(out, @"  reserve %.2f GB   OK    window base 0x%llx",
         total / 1073741824.0, (unsigned long long)base);
    return base;
}

/* Fallback: ask for a specific 4 GB-aligned base. Cheaper on address space, and
 * closer to what the port would do if the trimming reserve is refused. */
static uint64_t reserveWindowAtFixedBase(NSMutableString *out) {
    for (uint64_t base = 0x200000000ULL; base <= 0x1000000000ULL; base += WINDOW_ALIGN) {
        void *p = mmap((void *)(uintptr_t)base, (size_t)WINDOW_SPAN, PROT_NONE,
                       MAP_PRIVATE | MAP_ANON | MAP_NORESERVE | MAP_FIXED, -1, 0);
        if (p != MAP_FAILED && (uint64_t)(uintptr_t)p == base) {
            line(out, @"  fixed base        OK    window base 0x%llx",
                 (unsigned long long)base);
            return base;
        }
        if (p != MAP_FAILED) munmap(p, (size_t)WINDOW_SPAN);
    }
    line(out, @"  fixed base        FAIL  no 4 GB-aligned base accepted");
    return 0;
}

/* Commit one sub-range over the reservation. */
static void *commit(NSMutableString *out, const char *label, uint64_t addr, size_t len) {
    void *p = mmap((void *)(uintptr_t)addr, len, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED || (uint64_t)(uintptr_t)p != addr) {
        line(out, @"  commit %-8s   FAIL  errno=%d (%s)", label, errno, strerror(errno));
        return NULL;
    }
    volatile uint8_t *b = p;
    b[0] = 0x5A;
    b[len - 1] = 0xA5;
    BOOL rw = (b[0] == 0x5A && b[len - 1] == 0xA5);
    line(out, @"  commit %-8s   OK    0x%llx rw=%@", label,
         (unsigned long long)addr, rw ? @"yes" : @"NO");
    return rw ? p : NULL;
}

static BOOL suiteWindow(NSMutableString *out) {
    line(out, @"SUITE B: 4 GB-aligned window, N64 addr = W + v");

    uint64_t base = reserveWindowByTrimming(out);
    if (!base) base = reserveWindowAtFixedBase(out);
    if (!base) {
        line(out, @"  => NOT USABLE");
        line(out, @"");
        return NO;
    }

    BOOL ok = YES;
    ok &= (commit(out, "CART", base + CART_BASE, ROM_SIZE) != NULL);

    void *v1 = commit(out, "DRAM V1", base + DRAM_V1_BASE, DRAM_SIZE);
    ok &= (v1 != NULL);

    /* dram.c needs the KSEG0 view to be the same pages as V1, not a copy.
     * On Linux that is a memfd mapped twice; here it is vm_remap sharing. */
    BOOL aliased = NO;
    if (v1) {
        vm_address_t target = (vm_address_t)(base + DRAM_K0_BASE);
        vm_prot_t cur = VM_PROT_NONE, max = VM_PROT_NONE;
        kern_return_t kr = vm_remap(mach_task_self(), &target, DRAM_SIZE, 0,
                                    VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                    mach_task_self(), (vm_address_t)(uintptr_t)v1,
                                    FALSE, &cur, &max, VM_INHERIT_SHARE);
        if (kr != KERN_SUCCESS) {
            line(out, @"  alias K0->V1      FAIL  kr=%d (%s)", kr, mach_error_string(kr));
        } else if ((uint64_t)target != base + DRAM_K0_BASE) {
            line(out, @"  alias K0->V1      FAIL  moved to 0x%llx", (unsigned long long)target);
        } else {
            /* Prove the two views really share pages, in both directions. */
            volatile uint8_t *a = v1;
            volatile uint8_t *b = (volatile uint8_t *)(uintptr_t)target;
            a[0] = 0x11; a[DRAM_SIZE - 1] = 0x22;
            BOOL fwd = (b[0] == 0x11 && b[DRAM_SIZE - 1] == 0x22);
            b[4096] = 0x33;
            BOOL rev = (a[4096] == 0x33);
            aliased = fwd && rev;
            line(out, @"  alias K0->V1      %@    shared fwd=%@ rev=%@",
                 aliased ? @"OK  " : @"FAIL",
                 fwd ? @"yes" : @"NO", rev ? @"yes" : @"NO");
        }
    }
    ok = ok && aliased;

    /* The whole point: the game's 32-bit arithmetic must still land in-window. */
    if (ok) {
        uint32_t physical = 0x00001234;
        uint32_t kseg0 = physical | (uint32_t)DRAM_K0_BASE;
        volatile uint32_t *p = (volatile uint32_t *)(uintptr_t)(base + kseg0);
        *p = 0xDEADBEEF;
        volatile uint32_t *mirror =
            (volatile uint32_t *)(uintptr_t)(base + DRAM_V1_BASE + physical);
        BOOL match = (*mirror == 0xDEADBEEF);
        line(out, @"  KSEG0 arithmetic  %@    W+(phys|0x80000000) mirrors W+V1+phys",
             match ? @"OK  " : @"FAIL");
        ok = ok && match;
    }

    line(out, @"  => %@", ok ? @"USABLE" : @"NOT USABLE");
    line(out, @"");
    return ok;
}

static NSString *runProbe(void) {
    NSMutableString *out = [NSMutableString string];

    line(out, @"GoldenEye iOS address-space probe");
    line(out, @"build: %s", PROBE_VARIANT);
    line(out, @"iOS %@ on %@", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model);
    line(out, @"pointer size: %zu bytes", sizeof(void *));
    line(out, @"");

    /* __PAGEZERO is the thing that decides all of this. */
    line(out, @"__PAGEZERO size: %@", pagezeroSize());
    line(out, @"image slide:     0x%lx", (unsigned long)_dyld_get_image_vmaddr_slide(0));
    line(out, @"");

    line(out, @"SUITE A: the port's hardcoded low addresses");
    line(out, @"");
    BOOL cart = probeRegion(out, "CART   ", CART_BASE,    ROM_SIZE);
    BOOL v1   = probeRegion(out, "DRAM V1", DRAM_V1_BASE, DRAM_SIZE);
    BOOL k0   = probeRegion(out, "DRAM K0", DRAM_K0_BASE, DRAM_SIZE);
    BOOL lowOK = cart && v1 && k0;

    BOOL windowOK = suiteWindow(out);

    line(out, @"================================");
    line(out, @"A (hardcoded low addrs): %@", lowOK ? @"USABLE" : @"NOT USABLE");
    line(out, @"B (4GB window + alias):  %@", windowOK ? @"USABLE" : @"NOT USABLE");
    line(out, @"");
    if (lowOK) {
        line(out, @"VERDICT: the port's memory model works as-is.");
    } else if (windowOK) {
        line(out, @"VERDICT: rebase onto a 4 GB-aligned window.");
        line(out, @"Low addresses are unreachable, but W + v works and");
        line(out, @"the two DRAM views alias correctly with vm_remap.");
    } else {
        line(out, @"VERDICT: neither scheme works. The port needs real");
        line(out, @"pointer translation, not a rebase.");
    }
    line(out, @"================================");

    NSString *dir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (dir) {
        NSString *path = [dir stringByAppendingPathComponent:@"probe-report.txt"];
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        line(out, @"");
        line(out, @"saved to Documents/probe-report.txt");
    }
    return out;
}

@interface ProbeDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation ProbeDelegate

- (BOOL)application:(UIApplication *)app
        didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectZero];
    tv.editable = NO;
    tv.backgroundColor = UIColor.blackColor;
    tv.textColor = UIColor.greenColor;
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.text = runProbe();
    tv.alwaysBounceVertical = YES;

    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = UIColor.blackColor;
    tv.frame = vc.view.bounds;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:tv];

    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    return YES;
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeDelegate.class));
    }
}
