/*
 * PC entry point for the GoldenEye 007 port.
 *
 * Replaces the N64 boot path (boot.s -> init() -> mainproc() -> bossEntry()).
 * On the PC we:
 *   1. set up system / config / fs / rom
 *   2. load the ROM and map it at the cart base (0x10000000)
 *   3. init video (SDL2 + GL via fast3d), audio, input
 *   4. start the thread kernel and run the game's mainproc() as a real OS
 *      thread (it IS the N64 mainThread) — which runs bossEntry(), the real
 *      game loop. The game's own scheduler (src/sched.c) drives frames; see
 *      docs/internals.md.
 *   5. the host main thread then owns SDL event pumping for the lifetime of
 *      the process (Windows only dispatches window messages to the creating
 *      thread, and every game thread can be blocked on a queue).
 */

#include <stdlib.h>
#include <stdio.h>

#include <PR/ultratypes.h>
#include <PR/os.h>

#include "platform.h"
#include "system.h"
#include "n64mem.h"
#include "config.h"
#include "fs.h"
#include "romdata.h"
#include "dram.h"
#include "video.h"
#include "audio.h"
#include "input.h"
#include "mixer.h"
#include "crash.h"
#include "thread_config.h"

/* Defined in the game (src/init.c). The port calls into the real game entry. */
extern void mainproc(void *args);
extern OSThread mainThread; /* src/init.c:75 */

/* name:number pairs for the 21 solo levels (matches tools_pc/level_sweep.sh
 * and playtest.sh --list). boss.c decodes -level_XX as d0*10 + d1 - 0x210. */
static const struct { const char *name; const char *num; } kSoloLevels[] = {
    {"Dam","33"}, {"Facility","34"}, {"Runway","35"}, {"Surface1","36"},
    {"Bunker1","09"}, {"Silo","20"}, {"Frigate","26"}, {"Surface2","43"},
    {"Bunker2","27"}, {"Statue","22"}, {"Archives","24"}, {"Streets","29"},
    {"Depot","30"}, {"Train","25"}, {"Jungle","37"}, {"Control","23"},
    {"Caverns","39"}, {"Cradle","41"}, {"Aztec","28"}, {"Egypt","32"},
    {"Cuba","54"},
};

static void portPrintVersion(void)
{
    printf("GoldenEye 007 PC port\n"
           "  rom      : %s\n"
           "  platform : %s\n"
           "  build    : %s\n",
           GE007_ROMID, GE007_TARGET_PLATFORM, GE007_VERSION_HASH);
}

static void portPrintHelp(const char *argv0)
{
    portPrintVersion();
    printf("\nusage: %s [options] [-level_XX]\n\n"
           "  --help            this message\n"
           "  --version         build id only\n"
           "  -level_XX         boot straight into a solo level (per-level\n"
           "                    memory pools are auto-injected)\n\n"
           "config: ge007.ini in the data dir (written on first run).\n\n"
           "solo levels (-level_XX):\n", argv0 ? argv0 : "ge007");
    for (size_t i = 0; i < sizeof(kSoloLevels) / sizeof(kSoloLevels[0]); ++i) {
        printf("  %-10s -level_%s\n", kSoloLevels[i].name, kSoloLevels[i].num);
    }
}

static void portAtExit(void)
{
    /* Clean-exit only (exit(0) from videoPumpEvents). Crash/fatal paths call
     * abort(), which does not run atexit handlers. */
    videoSaveWindowState();
    configSave();
}

int main(int argc, char **argv)
{
    sysSetArgs(argc, argv);

    if (sysArgCheck("--version")) { portPrintVersion(); return 0; }
    if (sysArgCheck("--help") || sysArgCheck("-h")) {
        portPrintHelp(argv[0]);
        return 0;
    }

    sysLogPrintf(LOG_INFO, "GoldenEye 007 PC port starting "
                "(%s, %s)", GE007_ROMID, GE007_VERSION_HASH);

    /* Crash handler first, so any failure below is debuggable. */
    crashInit();

    /* 1. Platform + config + filesystem. */
    configLoad();
    atexit(portAtExit);   /* persist config + window geometry on clean exit */

    /* 2. Reserve the N64 address window, before anything maps into it. */
    n64memReserve();

    /* 2a. Load the ROM and map segments. */
    if (romdataInit() != 0) {
        /* romdataInit() has already listed every path it tried, which is
         * the answer; naming a directory here would be wrong on iOS, where
         * both roots expand to the app's Documents folder. */
        sysLogPrintf(LOG_ERROR, "Failed to load ROM. Put a GoldenEye .z64 at "
                    "one of the paths listed above.");
#if defined(PLATFORM_IOS)
        /* A sideloaded app has no console, and the log is no use to the user
         * if the app never wrote one, so put the failure on screen. The
         * message box needs a window to present against, and videoInit()
         * depends on nothing but config, so it is safe to bring up even
         * though no ROM loaded. */
        {
            char msg[1280];
            snprintf(msg, sizeof(msg),
                     "Build %s (%s).\n\n"
                     "Put a GoldenEye .z64 in this app's Documents folder, "
                     "named exactly one of the paths below, then reopen.\n\n%s",
                     GE007_VERSION_HASH, GE007_ROMID,
                     romdataGetSearchPaths());
            if (videoInit() == 0) {
                sysShowMessage("No ROM found", msg);
            }
        }
#endif
        return 1;
    }

    /* 2b. Commit DRAM inside the window: the s32-safe view holding cfb_16 and
     *     the mempools, plus its KSEG0 mirror (see port/src/dram.c). */
    dramReserve();

    /* 3. Video / audio / input. */
    if (videoInit() != 0) {
        sysLogPrintf(LOG_ERROR, "videoInit failed");
        return 1;
    }
    audioInit();
    mixerInit();
    inputInit();

    /* 4. Run the game. mainproc() runs as the N64 mainThread (a real OS
     *    thread with its own stack); it creates the rmon/idle/scheduler/
     *    audio threads and never returns in practice. */
    sysLogPrintf(LOG_INFO, "ROM mapped at 0x%08X (%u bytes); starting game",
                (unsigned)0x10000000, romdataGetRomSize());
    portKernelInit();
    osCreateThread(&mainThread, MAIN_THREAD_ID, &mainproc, NULL, NULL,
                   MAIN_THREAD_PRIORITY);
    osStartThread(&mainThread);

    /* 5. Host thread: pump SDL events until the window is closed / ESC.
     *    videoPumpEvents() exits the process on quit. */
    for (;;) {
        videoPumpEvents();
        sysSleep(8);
    }

    /* Unreachable in practice; clean up if we ever get here. */
    inputDestroy();
    mixerDestroy();
    audioDestroy();
    videoDestroy();
    romdataDestroy();
    configSave();

    return 0;
}
