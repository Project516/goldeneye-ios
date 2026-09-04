# goldeneye-ios

## What this is

An iOS port of GoldenEye 007 (N64), built on the existing decompilation and PC
port work. Ships as an unsigned IPA sideloaded with SideStore. No Mac is
involved: every Apple-toolchain build happens on GitHub Actions macOS runners.

## Direction

Optimize for, in order:

1. **Running at all on a real iPhone.** Correctness and boot-to-gameplay beat
   features, resolution, and polish.
2. **A platform layer that survives the game underneath changing.** The iOS
   layer (renderer backend, touch input, filesystem, app shell) should stay
   game-agnostic within the Rare N64 FPS engine family, so it can move between
   the GoldenEye and Perfect Dark port trees.
3. **Low memory and steady frame pacing.** Phones throttle and get killed for
   memory. A stable 30 fps beats a stuttering 60.

Explicit non-goals: App Store distribution, jailbreak support, multiplayer
netcode, and shipping anything ROM-derived.

## Hard rules

- **No ROM, and no raw extracted blob, enters this repo or an artifact.** The
  user supplies `GoldenEye.z64` on-device through the Files app. Upstream's
  `.gitignore` already excludes every raw asset (`assets/**/*.bin`, music,
  `Model.c`, setup/stan/text segments); we add `*.z64` and friends on top. Do
  not weaken either half.
- Upstream *does* track generated `.c` asset tables (1324 files, including
  level geometry). We inherit those by forking; they are already public
  upstream. Do not add more, and do not commit anything that only exists
  after running `extract_baserom`.
- **No GitHub Releases.** CI artifacts only, so builds are not distributed.
  The repo is public for free macOS runner minutes, not to hand out builds.
- macOS runners are the slow, contended ones. Keep `timeout-minutes` set and
  do not add push triggers that rebuild on unrelated changes.

## Glossary

- **decomp** - `goldeneye_src`, the matching decompilation that rebuilds a
  byte-identical N64 ROM. Source of truth for game logic.
- **port layer** - the `port/` directory added on top of a decomp to run its
  game code on a host OS, replacing libultra and the RSP/RDP.
- **fast3d** - the N64 display-list interpreter (`gfx_pc.cpp`) that turns RSP
  command streams into modern draw calls. Shared lineage across sm64-port,
  Perfect Dark PC, and the GoldenEye PC port.
- **rendering backend** - a concrete implementation of `gfx_rendering_api.h`
  (currently only desktop GL). The iOS one is new work.
- **DRAM views** - the port's two aliased mappings of N64 working RAM at
  `0x70000000` and `0x80000000`, plus the cart image at `0x10000000`. See
  `port/src/dram.c`. Whether iOS permits these is the project's gating risk.
- **__PAGEZERO** - the unmapped guard region at the bottom of a Mach-O address
  space, 4 GB by default on arm64, which covers all three DRAM/cart addresses.
- **probe** - `probe/`, the Stage 0 throwaway app that answers the __PAGEZERO
  question on real hardware.

## Reference checkouts

`code/` holds read-only upstream clones and is gitignored. Do not edit them,
and do not add them as submodules. The port itself is no longer one of them:
upstream `goldeneye-pc-port` is merged into this repo's history and tracked
via the `upstream` remote.

| Path | Role |
| --- | --- |
| `code/goldeneye_src` | the decomp; our ROM's sha1 matches its US target |
| `code/perfect_dark_pc` | mature, arm64-clean port of the sibling engine |
| `code/sm64coopdx-ios` | the iOS packaging and touch-control template |
| `code/SCInsta` | unsigned-IPA CI patterns |

## Reading order

Context is scarce. Load by tier, do not blind-read whole files.

- Always: `AGENTS.md` (repo root) and this file.
- Per task: `docs/porting-notes.md` for the recurring N64 to host bug classes.
  Skim the headers, read the class you need.
- On demand, never start to finish:
  - `docs/internals.md` for architecture and the phased plan. Read the section
    you need. 57 source comments point into it.
  - `docs/dev/findings.md` for the `Dxx` log. Jump via the index at the top of
    section F. 136 distinct `Dxx` labels appear in code comments.
  - `docs/dev/LINUX-PORT.md` now that Linux is the verification platform.

## Verifying a change

The Linux build runs, so use it. Do not rely on a clean compile.

```sh
cmake -S . -B build-pc -DROMID=ntsc-final && cmake --build build-pc -j"$(nproc)"
tools_pc/run-headless.sh 40             # front end
tools_pc/run-headless.sh 25 -level_09   # a solo level
```

**Never run it on the real display.** The window takes focus every time it
opens, so a sweep makes the machine unusable for whoever is at the keyboard.
`run-headless.sh` uses Xvfb, which gives Mesa software GL: slower, same frames.
It also unsets `WAYLAND_DISPLAY` and forces `SDL_VIDEODRIVER=x11`, without
which SDL2 picks its Wayland backend and opens a real window on the real
screen no matter what `DISPLAY` says. `xvfb-run` alone is not enough.
It prints the numbers below and symbolicates the first crash for you.

Do not rebuild while a sweep is running either. The build overwrites the
binary mid-sweep and every remaining level reports zero frames with no crash
and no heartbeat, which looks like a new failure mode and is not one. Copy the
binary aside, or wait.

**Judge a run on frames rendered, never on VI posts.** The `D51 vi post #N`
line comes off a timer and keeps counting at 60 Hz whether or not the game
submits a display list, so a completely hung level still logs thousands of
them. The honest number is on the quit line:

```sh
timeout 40 ./build-pc/ge007.x86_64 -level_09 2>&1 | tee run.log
grep -E "quit requested after|no frame rendered|FATAL" run.log
```

Front end is around 1100 frames in 40 s. Zero frames plus a `kernel heartbeat`
line means it hung, whatever the VI count says (that is D197). Two
verification passes were reported as clean before this was noticed.

**Check both paths.** The front end and `-level_09` exercise different code:
`-level_09` skips the front end entirely, so a front-end regression is
invisible to it. A change that touches thread stacks, the window, or the
segment table has to be run through both. See "A regression worth
remembering" in `memory-rebase.md`.

For memory work, watch for `n64mem:` and `D60` lines, which report the window
and any rejected DMA target.

**A Linux run proves nothing about iOS-only code.** Every
`#if defined(PLATFORM_IOS)` block is compiled out here, so that code is only
ever seen by a compiler in CI. Push and let `ios-configure` go green before
spending a macOS runner on `ios-ipa`: the configure job is about 90 s on a
warm cache, the IPA job is 8 minutes. A constructor calling a helper defined
below it cost a full IPA cycle to discover.

## Debugging the app on a device

There is no console and no Xcode. Two things make this tractable.

**Read the artifact before changing code.** The IPA is a zip and the binary is
a Mach-O; each of these answers a whole class of hypothesis in one command,
without a device:

```sh
gh release download <tag> --repo Project516/goldeneye-ios-builds -D /tmp/ipa
unzip -o /tmp/ipa/goldeneye-ios.ipa -d /tmp/ipa/x
python3 -c "import plistlib;print(plistlib.load(open('/tmp/ipa/x/Payload/GoldenEye.app/Info.plist','rb')))"
strings -a /tmp/ipa/x/Payload/GoldenEye.app/GoldenEye | grep -F ge007.log
```

The plist says whether file sharing and the bundle wiring are right. The
string table says whether a `PLATFORM_IOS` block made it into the build. The
symbol table says whether SDL's iOS entry point and its Objective-C classes
are linked (`_SDL_main` in our text plus `_main` in SDL's means libSDL2main's
`main` is calling ours). GNU `nm` cannot read Mach-O; the 20-line LC_SYMTAB
reader in D200 works. Doing this retired four hypotheses at once, after I had
already committed a fix for one of them that turned out to be a no-op.

**The app reports to Documents, and stamps its build.** `ge007-boot.txt` is
written by a constructor before `UIApplicationMain`; `ge007.log` is written
from the first log line in `main`; the no-ROM path raises an SDL alert. Both
files and the alert carry `GE007_VERSION_HASH`, because a report from the
wrong build looks exactly like a bug. Note that the Files app only lists the
app under On My iPhone once Documents is non-empty, so "no folder" means
"nothing was written", not "file sharing is off".

## Dispatching a subagent

Every brief needs all of: the exact files it may touch, disjoint from any
other running agent; a budget in cycles or minutes; what to do on expiry;
what is already ruled out; and the shape of the report. Tell it to read
`docs/porting-notes.md` first and to append anything generalisable to it.

## CI and delivery

This repo is public so macOS runner minutes are free. That also means its
Actions artifacts are downloadable by anyone, so **nothing playable is ever
published here**. `linux-build.yml` is a compile check that publishes nothing;
`ios-configure.yml` records the current iOS error profile in the run summary.

`ios-ipa.yml` (manual only) builds an unsigned IPA and drops it as a release
in the private `Project516/goldeneye-ios-builds` repo. SideStore re-signs on
device, so the IPA stays unsigned and nothing needs decrypting.

Secrets:

| Secret | Used by | What it is |
|---|---|---|
| `IPA_DROP_TOKEN` | `ios-configure`, `ios-ipa` | Fine-grained PAT with `contents: write` on `goldeneye-ios-builds` and nothing else. |

That one token does two jobs: publishing the IPA, and downloading the ROM,
which lives as the `rom-ntsc-u` release asset on the same private repo. A
Cloudflare-fronted R2 URL was the first choice and still works from a
workstation, but it 403s a GitHub runner, so the bucket is out of the CI path.
Splitting off a read-only token for the ROM would be tighter; one token is what
exists today.

`ios-configure` treats the ROM as optional: without it `gen_romassets.py`
sizes the images segment from the CSV maximum, which is short and wrong at
runtime but compiles fine, and that workflow only reports the error profile.
`ios-ipa` treats it as required. Both delete it, and everything derived from
it, before the job ends. Run `ios-ipa` with `check_token_only=true` to verify
the token on a Linux runner without building anything.

Because the repo is public, a workflow must never run with these secrets on a
`pull_request` from a fork, and must never use `pull_request_target`. GitHub
withholds secrets from fork PRs on `pull_request`, so keep it that way.

`ios-ipa.yml` produces a real IPA: the bundle target and `Info.plist` landed,
and the arm64 Mach-O links. It will not render yet, because fast3d still
targets desktop GL rather than GLES3 or Metal, so expect an app that installs
and launches and then fails at renderer init. That is the point of building
it: the renderer work needs something to test against.

`ios-configure.yml` ends by requiring `GoldenEye.app/GoldenEye` to exist. The
build step is `continue-on-error` so the diagnostic steps can still harvest
the error profile, which used to mean a failed build reported success. Do not
read that job's green check as a working build without checking that final
step ran.

## Upstream

This is a hard fork. It does not track or merge
[goldeneye-pc-port](https://github.com/jkdansereau/goldeneye-pc-port), and the
squashed import means `git cherry-pick` will not work. Individual upstream
fixes are still worth porting by hand, roughly monthly. Diff the file, apply
the change, and credit the upstream commit in the message, as the Linux
bring-up fixes did.

To review what is new upstream:

```sh
git remote add upstream https://github.com/jkdansereau/goldeneye-pc-port.git
git fetch upstream --tags
git log --oneline <last-sync>..upstream/master
```

Import base: `e4fc9dd0`. Synced through: **`v0.1.0` (`cbed324d`, 2026-09-04)**
-- the two code fixes in that tag (D188 `va_list*`, D189 stack overruns) were
already here from upstream's unmerged branches, so the sync took docs only.
Update this line on every sync.
