# ReqGramPythonRuntime

Actual embedded CPython, isolated from environment/site/CWD search paths, **not
a security sandbox**. The main client can execute locally imported plugins after
an explicit untrusted-code warning, but Python can access app-process resources,
loop forever, consume memory, or start threads. There is no hard cancellation or
per-plugin interpreter isolation. See `ReqGramPluginAPI.md` for the current
bounded public contract and `MAIN_CLIENT_INTEGRATION.md` for integration status.

## End-to-end path

`RGPythonRuntime.shared evaluateExpression:completion:` → serial dispatch queue
→ lazy isolated `PyConfig` initialization → GIL-protected evaluation → native
string/NSError → main-queue completion. The interpreter lives for the process;
it is never finalized/reinitialized. `setExecutionEnabled:` is ordered on the
same queue and rejects future evaluations, not an interrupt for current work.

`reqgram_host` is a real C extension registered before initialization:

- `log(str)`: bounded 4096-byte NSLog diagnostic, not manager log retention.
- `save(bytes)` / `load()`: atomic 64-KiB runtime-owned blob under Application
  Support/ReqGramPythonRuntime/host.bin; survives process relaunch. **Not**
  per-plugin storage, keychain, or access to account data.
- `lifecycle()`: reports the native execution gate.

Swift callers can import the ObjC Bazel module; no Python objects cross the API.
The standalone `reqgram_host` smoke module described above is not the plugin API.
The main client now adds plugin-bound lifecycle, manager/UI, account metadata,
bounded local message reads/events/mutations, UI, storage/log, and network
operations. It still provides no general Telegram/MTProto API or security sandbox.

## Reproduce verification

```sh
python3 third-party/PythonRuntime/prepare.py
python3 Swiftgram/ReqGramPythonRuntime/Tests/smoke.py
build-input/bazel-8.4.2-darwin-arm64 build \
  //Swiftgram/ReqGramPythonRuntime:ReqGramPythonSmoke \
  --ios_multi_cpus=sim_arm64 --ios_minimum_os=14.0 --lockfile_mode=off
python3 Swiftgram/ReqGramPythonRuntime/Tests/smoke.py booted \
  bazel-bin/Swiftgram/ReqGramPythonRuntime/ReqGramPythonSmoke.ipa
```

Use an explicit simulator UDID instead of `booted` when multiple devices run.
Harness installs only `local.reqgram.python.smoke`, executes twice, and requires
both success markers plus second-process persistence. Python on the host only
prepares resources and invokes build tools; **evaluation occurs in the iOS app**.

Verified on Xcode 26.6 (17F113), iOS SDK/simulator 26.5, arm64 iPhone 17
`DF4A14F9-D2C7-49D5-AF55-969A40E23727`. Both direct Clang and Bazel-packaged apps
passed. Tests cover expression 42, pure-Python collections/JSON and bundled
module, `sys.platform == 'ios'`, two bundle-only paths, isolated/no-bytecode
flags, division-by-zero exception/recovery, gate disable/re-enable, native log,
storage limit and persistence after process relaunch. Device slice compiled and
linked with the same shim but was not deployed to hardware.

Artifacts:
- `Tests/out/ReqGramPythonSmoke.app`: standalone simulator harness.
- `Tests/out/device-link-check`: arm64 iOS executable, not signed for deployment.
- `Tests/out/bazel/Payload/ReqGramPythonSmoke.app`: tested Bazel app.
- `Tests/out/simulator-results.log`, `Tests/out/artifacts.json`: actual evidence.
- `bazel-bin/Swiftgram/ReqGramPythonRuntime/ReqGramPythonSmoke.ipa`.

The standalone smoke evidence above does not prove the full plugin API. The full
Telegram Simulator application and the safe 28-method fixture have since been
built and run, while physical-device execution and live success paths for every
mutation/network operation remain outside that evidence. Use repository Bazel
8.4.2, not Homebrew Bazel 9 (removed native objc_library).

## Main-client status

`SGSimpleSettings/Sources/ReqGramPluginManager.swift` now supplies immutable
validated package snapshots, plugin identity and permission checks, per-plugin
storage/log callbacks, safe-mode admission, lifecycle state, and failure
reporting to `ReqGramEmbeddedExecutor`. Running state remains session-derived,
and imported code remains untrusted. App Store policy for downloaded code and
physical-device signing/deployment still require separate review.
