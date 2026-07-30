# bukalemun-lo-patches

Build patches and scripts used to compile **LibreOffice core** as a native
Android library (`liblo-native-code.so`, arm64-v8a) for the app
**Bukalemun PDF**.

This repository exists to satisfy the **MPL-2.0** source-availability
obligation: LibreOffice is licensed under the Mozilla Public License 2.0, whose
copyleft is *file-based*. Everything we modified in LibreOffice's own files is
published here.

## What was modified

| File | Change | Why |
|---|---|---|
| `android/Bootstrap/Makefile.shared` | `NSSLIBS` emptied | We build with `--disable-nss`, but the Android packaging step links the NSS libraries unconditionally |
| `android/Bootstrap/Makefile.shared` | 16 KB page-size flags added to the link command | See "16 KB alignment" below |

That is the entire diff — see [`patches/`](patches/).

Two further build-time workarounds are **not** patches to LibreOffice source,
so they live in the build script instead:

- an empty `libxmlsec1-nss.a` archive is created at
  `workdir/UnpackedTarball/xmlsec/src/nss/.libs/`, because the linker still
  looks for it when NSS is disabled;
- the WSL environment is sanitised (see below).

> Note: on this LibreOffice revision `bin/lo-all-static-libs` needed no change —
> it contained no NSS linker flags. Earlier notes of ours said otherwise; the
> generated diff was empty, so no patch is shipped for it.

## Versions

| | |
|---|---|
| LibreOffice | branch `libreoffice-24-8`, commit `d1c9e0e4e1ddeb24fe8f93e56860b3765043f8b1` (2025-06-02) |
| Android NDK | r26d |
| Android SDK | platform 34, build-tools 34.0.0 |
| Target ABI | `arm64-v8a`, minimum API 24 |
| Host | Ubuntu 22.04 (WSL2), GCC 12 |

## How to build

```bash
bash build-lokit-wsl.sh            # full build
bash build-lokit-wsl.sh --relink   # relink only (fast)
```

The script downloads the NDK and SDK, clones LibreOffice, applies the patch,
builds, and finally verifies that every produced `.so` reports **16 KB page
alignment** (`0x4000`), which Google Play has required for 64-bit devices since
1 November 2025.

## Things that cost us time — so they don't cost you any

**`--with-distro` must be the first line of `autogen.input`.** The
`LibreOfficeAndroid` distro config sets `--host=arm-linux-androideabi` (32-bit).
Options given *after* it win, so our `--host=aarch64-linux-android` must follow
it. In the reverse order you silently get a 32-bit build.

**NSPR does not compile with NDK 26** (a `stat64` mismatch), hence
`--disable-nss` and the patch above.

**`--with-extra-cflags` does not exist in 24.8.** configure aborts with
`unrecognized options`. The Android target already produces position-independent
code.

**Do not inherit the Windows `PATH` under WSL.** LibreOffice's `configure.ac`
(around line 323) checks whether `WSL_DISTRO_NAME` is set *and* `PATH` contains
`mingw64`; if both hold it switches to "cross-compile to Windows from WSL" mode
and demands `strawberry-perl-portable`. Git Bash puts `mingw64` on the Windows
PATH, which WSL inherits. The script strips `mingw`/`/mnt/*` entries from `PATH`
before configuring — this also speeds up the build noticeably.

**The output is not in `instdir/`.** The linked library lands at
`android/obj/local/arm64-v8a/liblo-native-code.so`.

**The build target is `build`,** not `build-nocheck`, on this branch.

**16 KB alignment cannot be passed through `LDFLAGS`.** The rule that links
`liblo-native-code.so` in `android/Bootstrap/Makefile.shared` builds its own
`$(CXX)` command line and never reads `LDFLAGS`. Exporting the flags in the
environment produces a build that succeeds and a library that is still 4 KB
aligned — which Google Play rejects, with no warning anywhere in the build
output. The flags must be written into that command line, which is what the
patch does. Always verify afterwards:

```bash
llvm-readelf -l liblo-native-code.so | grep -m1 " LOAD "   # must end in 0x4000
```

**The empty `libxmlsec1-nss.a` must be created immediately before linking,
not once at the start.** Unpacking the xmlsec tarball during the build wipes
`workdir/UnpackedTarball/xmlsec/src/nss/.libs/`, so a placeholder created
beforehand is gone by the time the linker needs it — and you only find out
after the whole build has completed. The script creates it right before `make`
and retries once if it disappeared anyway.

**`libc++_shared.so` from NDK r26 is 4 KB aligned.** The script deliberately
does not ship it; take it from NDK 27 or newer, which is 16 KB aligned.

## Licence

The patch in `patches/` applies to LibreOffice files and is therefore covered by
the **Mozilla Public License, v. 2.0** — <https://mozilla.org/MPL/2.0/>.

`build-lokit-wsl.sh` is released under the same licence for simplicity.

The Bukalemun PDF application itself is a separate, proprietary work and is not
covered by this repository. Under MPL-2.0 §3.3 an MPL-licensed component may be
combined with proprietary code in a "Larger Work"; only the MPL-licensed files
themselves must remain under the MPL, and those are published here.

LibreOffice is a registered trademark of The Document Foundation. This project
is not affiliated with or endorsed by The Document Foundation.
