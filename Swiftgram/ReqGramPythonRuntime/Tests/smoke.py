"""Build the actual ObjC shim into an account-free arm64 iOS simulator app."""
import hashlib
import json
import pathlib
import plistlib
import shutil
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[3]
MODULE = ROOT / 'Swiftgram/ReqGramPythonRuntime'
VENDOR = ROOT / 'third-party/PythonRuntime/vendor'
OUT = MODULE / 'Tests/out'

def run(*args):
    return subprocess.check_output([str(a) for a in args], stderr=subprocess.STDOUT, text=True)

def main():
    OUT.mkdir(exist_ok=True)
    app = OUT / 'ReqGramPythonSmoke.app'
    app.mkdir(exist_ok=True)
    resources = app / 'ReqGramPythonResources.bundle'
    resources.mkdir(exist_ok=True)
    shutil.copy2(VENDOR / 'python313.zip', resources)
    shutil.copy2(VENDOR / 'Python.xcframework/lib/python3.13/LICENSE.txt', resources)
    shutil.copy2(MODULE / 'Resources/reqgram_smoke.py', resources)
    (resources / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.reqgram.python.resources', 'CFBundlePackageType': 'BNDL'}))
    (app / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': 'local.reqgram.python.smoke', 'CFBundleExecutable': 'ReqGramPythonSmoke',
        'CFBundleName': 'ReqGramPythonSmoke', 'CFBundlePackageType': 'APPL',
        'CFBundleVersion': '1', 'CFBundleShortVersionString': '1.0',
        'MinimumOSVersion': '14.0', 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
    }))
    for sdk, target, slice_name in [
        ('iphonesimulator', 'arm64-apple-ios14.0-simulator', 'ios-arm64_x86_64-simulator'),
        ('iphoneos', 'arm64-apple-ios13.0', 'ios-arm64'),
    ]:
        framework = VENDOR / 'Python.xcframework' / slice_name
        output = app / 'ReqGramPythonSmoke' if sdk == 'iphonesimulator' else OUT / 'device-link-check'
        print(run('xcrun', '--sdk', sdk, 'clang', '-target', target, '-isysroot', run('xcrun', '--sdk', sdk, '--show-sdk-path').strip(),
                  '-fobjc-arc', '-fblocks', '-I', MODULE / 'Sources', '-F', framework,
                  MODULE / 'Sources/RGPythonRuntime.m', MODULE / 'Tests/main.m',
                  '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'Python',
                  '-Wl,-rpath,@executable_path/Frameworks', '-o', output))
    frameworks = app / 'Frameworks'
    frameworks.mkdir(exist_ok=True)
    dest = frameworks / 'Python.framework'
    dest.mkdir(exist_ok=True)
    source = VENDOR / 'Python.xcframework/ios-arm64_x86_64-simulator/Python.framework'
    for name in ('Python', 'Info.plist'):
        shutil.copy2(source / name, dest)
    print(run('codesign', '--force', '--sign', '-', dest))
    print(run('codesign', '--force', '--sign', '-', app))
    device = sys.argv[1] if len(sys.argv) > 1 else 'booted'
    if len(sys.argv) > 2:
        # Optional second argument verifies Bazel's actual resource/framework bundle.
        unpacked = OUT / 'bazel'
        with zipfile.ZipFile(sys.argv[2]) as ipa:
            ipa.extractall(unpacked)
        app = unpacked / 'Payload/ReqGramPythonSmoke.app'
        (app / 'ReqGramPythonSmoke').chmod(0o755)
        (app / 'Frameworks/Python.framework/Python').chmod(0o755)
    print(run('xcrun', 'simctl', 'install', device, app))
    logs = []
    for index in range(2):
        log = run('xcrun', 'simctl', 'launch', '--terminate-running-process', '--console', device, 'local.reqgram.python.smoke')
        print(log)
        assert 'REQGRAM_PYTHON_SMOKE_PASS' in log, log
        if index == 1:
            assert '"persisted": true' in log, log
        logs.append(log)
    (OUT / 'simulator-results.log').write_text('\n'.join(logs))
    paths = [VENDOR / 'python313.zip', *[VENDOR / 'Python.xcframework' / s / 'Python.framework/Python' for s in ('ios-arm64', 'ios-arm64_x86_64-simulator')]]
    report = {str(p.relative_to(ROOT)): {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in paths}
    (OUT / 'artifacts.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
