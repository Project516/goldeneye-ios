# Security policy

This is a hobby game port with no users, no network service, and no
secrets. There isn't much of a security surface here, honestly. The two
realistic risks are:

- the engine parsing your own ROM and asset files at load time. A malformed
  ROM or asset could in principle crash it, or worse, and
- the build, extraction, and CI scripts.

## Reporting a problem

Please do not open a public issue for a security problem. Use GitHub's
private vulnerability reporting instead: Security -> Report a vulnerability
on this repository
(<https://github.com/Project516/goldeneye-ios/security/advisories/new>).

If that does not work for you, a regular issue is fine too, this project has
no users to protect from disclosure.

Include what you can:

- the commit hash (`git rev-parse HEAD`),
- OS and how you built (region, Linux vs iOS probe),
- a minimal reproduction, and
- the crash log or a stack trace if you have one.

## Scope

In scope: memory-safety bugs in the `port/` layer or the iOS probe, and
problems in the CI workflows or build scripts.

Out of scope: bugs inherited unchanged from the upstream
[GoldenEye 007 decompilation](https://github.com/n64decomp/007) (report those
there, not here), missing-asset or wrong-ROM errors, and anything requiring a
ROM or assets this project does not distribute.

## Supported versions

Only the tip of `main` is supported. There are no releases yet.
