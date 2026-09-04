#ifndef _VTXSTORE_H_
#define _VTXSTORE_H_
#include <ultra64.h>

void sub_GAME_7F09B820(void);
void sub_GAME_7F09BBBC(void);
#ifdef PORT
/* D197: the return value is a Vertex address, taken straight out of the
 * store's unk00 field, and every caller casts it back to Vertex *. s32
 * truncates it. Widening the return type changes nothing else; the `return 0`
 * paths stay valid as a null pointer constant. */
Vertex *vtxstore_allocate(s32 arg0, s32 type, s32 arg2, s32 arg3);
#else
s32 vtxstore_allocate(s32 arg0, s32 type, s32 arg2, s32 arg3);
#endif
void sub_GAME_7F09C044(Vertex* arg0);

#endif
