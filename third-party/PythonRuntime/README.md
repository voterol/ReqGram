# Pinned native iOS CPython

Run `python3 third-party/PythonRuntime/prepare.py` from the repository root
(Python 3.12+ for the safe tar data filter). Downloads and extracted vendor files
are intentionally ignored; the build never downloads implicitly. No upstream
installer, compiler stub, or testbed script is executed.

## Provenance verified 2026-09-18

- Official embedding documentation: https://docs.python.org/3.13/using/ios.html
- Upstream: https://github.com/beeware/Python-Apple-support
- Release: https://github.com/beeware/Python-Apple-support/releases/tag/3.13-b15
- Tag commit: `7e8f7461423f7b237f0a0e0540ffb0bd8339fc6e`
- Asset ID: `544065217`, CPython **3.13.15**, support build **b15**.
- URL: https://github.com/beeware/Python-Apple-support/releases/download/3.13-b15/Python-3.13-iOS-support.b15.tar.gz
- Size: **32,566,713 bytes**.
- SHA-256: `80175765a31babe43b0910395cf86ba4e8412adf1902b069d55b74d523ecc5d1`
- Download hash matched GitHub release API `digest`; this is integrity/provenance
  from the publisher's HTTPS release, **not an independent signature audit**.

`downloads/Python-3.13-iOS-support.b15.tar.gz` is retained locally. Extraction
rejects absolute/traversal/special-file entries and uses tarfile's data filter to
validate links. The archive includes relative libpython symlinks; none are used
to substitute a host runtime.

## Local build inputs

All paths below are relative to this directory:

| Path | Bytes | SHA-256 |
|---|---:|---|
| `vendor/Python.xcframework/ios-arm64/Python.framework/Python` | 5,469,624 | `47b022e5ce098745bccc3bce55028aa58a8aea09eb636686e8cb91799ccb093a` |
| `vendor/Python.xcframework/ios-arm64_x86_64-simulator/Python.framework/Python` | 10,970,776 | `296bf6c76bfde83a24c8f6fff4e7c311e9cee3e449459aef117c4e9ef4cfc5b3` |
| `vendor/python313.zip` | 10,301,804 | `52629bd530bcffa69c88de28cbd960eef3d74ab31d8d2016ec8bf844c5ec7e52` |

Mach-O `LC_BUILD_VERSION`: device arm64 **IOS 13.0**, simulator arm64
**IOSSIMULATOR 14.0**, simulator x86_64 **IOSSIMULATOR 13.0**; SDK 26.5.
Core binary depends only on CoreFoundation and libSystem plus its own
`@rpath/Python.framework/Python` install name. No host macOS libpython.

CPython license: **PSF License Version 2**, including historical notices, at
`vendor/Python.xcframework/lib/python3.13/LICENSE.txt`; copied into the resource
bundle. BeeWare support project is MIT; see upstream LICENSE at the
pinned commit. The downloaded archive also contains optional BZip2, libFFI,
mpdecimal, OpenSSL and XZ extensions, but these are **not shipped by this BUILD**.
Review their notices before enabling them.

The deterministic, uncompressed ZIP contains pure `.py` standard-library files,
excluding tests, tkinter, idlelib, ensurepip, lib-dynload and target sysconfigdata.
Stored ZIP entries permit bootstrap without a zlib extension. This is not a
complete stdlib: modules needing absent native extensions fail normally.
Native extensions must be converted to signed frameworks with `.fwork` markers
per the official iOS documentation before adding them. Do not ship loose `.so`s.
