## goldeneye-ios

There is no release yet. Nothing here is playable on iOS: the port is still
at the memory-rebase stage (see `docs/ios/plan.html` and `docs/ios/AGENTS.md`).
The Linux build boots, renders the intro and front end, and loads all 21 solo
missions, but has no audio. Neither is packaged for distribution today.

This file is the template for when there is something to announce. When that
day comes, fill in the sections below rather than inventing new ones.

### What changed

<!-- One paragraph, plain language, what a user notices. -->

### Downloads

The build is not distributed as a Linux binary. The iOS build is produced as
an unsigned IPA by GitHub Actions and sideloaded with SideStore, there is no
Mac involved anywhere in that pipeline. Once a release exists, list the
artifact names and the workflow that produced them here.

### Running it

You supply your own GoldenEye 007 (USA) N64 ROM
(sha1 `abe01e4aeb033b6c0836819f549c791b26cfde83`). No ROM or ROM-derived data
is distributed by this project, ever. Full steps are in `docs/building.md`.

### Source & docs

<https://github.com/Project516/goldeneye-ios>. This is a hard fork of
[goldeneye-pc-port](https://github.com/jkdansereau/goldeneye-pc-port), built
on the [GoldenEye 007 decompilation](https://github.com/n64decomp/007). It
does not track upstream and will not merge from it. Licensed AGPL-3.0
(`LICENSE`); the original MIT notice from upstream is preserved in
`LICENSE.MIT`. Non-commercial fan project, not affiliated with any rights
holder.
