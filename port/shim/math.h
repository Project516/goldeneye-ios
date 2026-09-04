/*
 * PC port shim for <math.h>.
 *
 * The N64 include/math.h sits earlier on the include path than the toolchain's
 * own header. In a C TU that is what the game wants. In a C++ TU it breaks
 * libc++: <cmath> includes <math.h> and then asserts it received the C++
 * standard library's wrapper, so getting the N64 header instead is a hard
 * error ("tried including <math.h> but didn't find libc++'s <math.h>").
 * Route C++ TUs to the host header by absolute path, the same trick as
 * port/shim/string.h and port/shim/stddef.h.
 *
 * Inert in the N64 build (port/shim is not on its include path).
 */
#if defined(__cplusplus)
#include "hostmath.h"
#else
#include "include/math.h"
#endif
