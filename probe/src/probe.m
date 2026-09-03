/*
 * Address-space probe for the GoldenEye iOS port.
 *
 * goldeneye-pc-port requires three fixed mappings that all sit below the 4 GB
 * line: the cart image at 0x10000000 and the two DRAM views at 0x70000000 and
 * 0x80000000 (port/src/romdata.c, port/src/dram.c). On arm64 Mach-O the whole
 * low 4 GB is normally covered by __PAGEZERO, so this probe reports whether a
 * sideloaded app can claim those addresses, and whether shrinking __PAGEZERO
 * changes the answer.
 *
 * Results are shown on screen and written to Documents/probe-report.txt so they
 * can be pulled off the device with the Files app.
 */

#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/getsect.h>
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

static NSString *runProbe(void) {
    NSMutableString *out = [NSMutableString string];

    line(out, @"GoldenEye iOS address-space probe");
    line(out, @"build: %s", PROBE_VARIANT);
    line(out, @"iOS %@ on %@", UIDevice.currentDevice.systemVersion, UIDevice.currentDevice.model);
    line(out, @"pointer size: %zu bytes", sizeof(void *));
    line(out, @"");

    /* __PAGEZERO is the thing that decides all of this. */
    const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(0);
    const struct segment_command_64 *pz = getsegbynamefromheader_64(hdr, "__PAGEZERO");
    line(out, @"__PAGEZERO size: %@",
         pz ? [NSString stringWithFormat:@"0x%llx", pz->vmsize] : @"(absent)");
    line(out, @"image slide:     0x%lx", (unsigned long)_dyld_get_image_vmaddr_slide(0));
    line(out, @"");

    BOOL cart = probeRegion(out, "CART   ", CART_BASE,    ROM_SIZE);
    BOOL v1   = probeRegion(out, "DRAM V1", DRAM_V1_BASE, DRAM_SIZE);
    BOOL k0   = probeRegion(out, "DRAM K0", DRAM_K0_BASE, DRAM_SIZE);

    line(out, @"================================");
    if (cart && v1 && k0) {
        line(out, @"VERDICT: all three fixed regions are usable.");
        line(out, @"goldeneye-pc-port's memory model can be kept as-is.");
    } else {
        line(out, @"VERDICT: fixed low mappings are NOT available.");
        line(out, @"The port's DRAM/cart scheme must be rebased off");
        line(out, @"hardcoded addresses before it can run on iOS.");
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
