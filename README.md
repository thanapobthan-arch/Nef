# NefCopy

macOS file transfer and checksum verification application.

**Version 21.1.4 · build 2114.20 · Automatic Buffer**

## Features

- Automatic per-file buffers: 16 MiB for files at least 256 MiB; 8 MiB for smaller files.
- XXH64BE checksums and full destination readback; optional independent source verification.
- Duplicate protection, pause/resume, retry and persistent queue.
- Multiple destinations, cascading transfers and ASC MHL support.
- Existing queued jobs retain their saved buffer policy.

This source is the existing production version. The experimental single-destination pipeline is not included. No general speed improvement is claimed.

## Build and test

Requires macOS 13 or later and Xcode / Swift 5.9 or later.

```sh
chmod +x test_nefcopy.sh build_dmg.sh
./test_nefcopy.sh
./build_dmg.sh
```

The packaging script runs the tests and creates the app and DMG under `dist/`. It replaces this repository's `.build/` and `dist/` folders. Packages built by this script are ad-hoc signed, not Apple-notarized. The supplied release downloads are for Apple Silicon; building on another architecture has not been validated here.

## Validation

The recorded validation for build 2114.20 passed 338 tests. A generated-data real-drive comparison completed 24 transfers with 2,192 SHA-256 file-pair checks. These are historical results, not a new test run performed while preparing this repository.

## Downloads

Put the supplied DMG and app ZIP in this repository's Releases section. Finish active jobs and close the old app before installing. Do not run two app versions against the same queue.

## Third-party code

The bundled xxHash source retains its BSD 2-Clause license notice in `Sources/CXXHash/xxhash.h`. No new license grant for the NefCopy application is added by this packaging step.
