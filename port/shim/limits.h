/*
 * PC port shim for <limits.h>. Same reason as port/shim/math.h: the N64
 * include/limits.h hardcodes N64 integer widths and is missing macros the
 * SDK's own headers expect, so C++ TUs get the host header by absolute path
 * while C TUs keep the decomp's.
 *
 * Inert in the N64 build (port/shim is not on its include path).
 */
#if defined(__cplusplus)
#include "hostlimits.h"
#else
#include "include/limits.h"
#endif
