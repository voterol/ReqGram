"""Download a pinned iOS artifact; never execute upstream installer scripts."""
import hashlib
import pathlib
import tarfile
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent
URL = 'https://github.com/beeware/Python-Apple-support/releases/download/3.13-b15/Python-3.13-iOS-support.b15.tar.gz'
SHA256 = '80175765a31babe43b0910395cf86ba4e8412adf1902b069d55b74d523ecc5d1'

def main():
    downloads = ROOT / 'downloads'
    downloads.mkdir(exist_ok=True)
    archive = downloads / URL.rsplit('/', 1)[1]
    if not archive.exists():
        with urllib.request.urlopen(URL, timeout=120) as response:
            archive.write_bytes(response.read())
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256:
        raise ValueError('checksum mismatch')
    vendor = ROOT / 'vendor'
    vendor.mkdir(exist_ok=True)
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError('Unsafe archive member: ' + member.name)
        tar.extractall(vendor, filter='data')
    print(f'Verified {archive}: {archive.stat().st_size} bytes SHA256={SHA256}')
    # A stored ZIP needs no zlib extension during interpreter bootstrap.
    # Only pure Python is shipped in this initial runtime; no loose .so files.
    stdlib = vendor / 'Python.xcframework/lib/python3.13'
    assert (stdlib / 'encodings/__init__.py').is_file()
    with zipfile.ZipFile(vendor / 'python313.zip', 'w', compression=zipfile.ZIP_STORED) as out:
        for source in sorted(stdlib.rglob('*.py')):
            relative = source.relative_to(stdlib)
            if not any(p in ('test', 'tests', 'idlelib', 'tkinter', 'ensurepip', 'lib-dynload') for p in relative.parts) and not source.name.startswith('_sysconfigdata'):
                info = zipfile.ZipInfo(str(relative), date_time=(2026, 1, 1, 0, 0, 0))
                out.writestr(info, source.read_bytes())

if __name__ == '__main__':
    main()
