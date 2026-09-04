#ifndef _INITANITABLE_H_
#define _INITANITABLE_H_
#include <ultra64.h>
#include <assets/animationtable_data.h>



/**
 * Struct to hold animation data. This is never instantiated.
 * Instead, only a pointer to this will exist.
 */
struct animation_table_data {
    /**
     * Array length is arbitrary and shouldn't matter. The largest offset
     * into this is for the last animation pointer 0xE7C0, so just choosing
     * a value bigger than that, like u16_max_value.
    */
    u8 data[0xffff];
};

/**
 * Data holder for animations.
 */
extern struct animation_table_data* ptr_animation_table;

/* An animation record from an ANIM_DATA_* id. Those ids are absolute linker
 * symbols whose value is a byte offset into the table, so the record address
 * is the table's real data pointer plus that offset.
 *
 * The decomp writes this as `(s32)id + (s32)&ptr_animation_table->data`, which
 * truncates the table pointer on PC. Three files had already fixed it with
 * identical local macros while chraction.c and bondview2.c still built
 * pointers the truncating way and crashed in modelSetAnimFrame (D197), so it
 * lives here now, next to the table.
 *
 * Comparison sites that truncate BOTH sides are consistent and are left as the
 * decomp wrote them. */
#ifdef PORT
#define ANIMREC(id) \
    ((void *)((u8 *)&ptr_animation_table->data + (uintptr_t)(u32)(uintptr_t)(id)))
#else
#define ANIMREC(id) ((void *)((s32)(id) + (s32)&ptr_animation_table->data))
#endif

/**
 * Contains offsets into ptr_animation_table for player and guard animations.
 * The index of each value corresponds to `enum ANIMATION`.
 * The value corresponds to (e.g. index=0) PTR_ANIM_idle (same as ANIM_DATA_idle)
*/
extern s32 animation_table_ptrs1[];

/**
 * Contains offsets into ptr_animation_table for object/vehicle animations.
 * The index of each value corresponds to `enum AIRCRAFT_ANIMATION`.
 * The value corresponds to (e.g. index=0) PTR_ANIM_helicopter_cradle (same as ANIM_DATA_helicopter_cradle)
 *
 * D32/D33: s32 offsets (N64 layout — 4-byte elements on both targets);
 * cast to ModelAnimation * at the use sites.
*/
extern s32 animation_table_ptrs2[];

#endif
