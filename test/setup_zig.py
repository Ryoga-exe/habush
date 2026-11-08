"""Install the project's Zig version from the official, checksummed archive."""
import hashlib
import json
import os
from pathlib import Path
import platform
import tarfile
import tempfile
import urllib.request
import zipfile

version = "0.16.0"
arch = {"AMD64": "x86_64", "arm64": "aarch64"}.get(platform.machine(), platform.machine())
system = {"Darwin": "macos", "Windows": "windows", "FreeBSD": "freebsd"}.get(
    platform.system(), platform.system().lower())
with urllib.request.urlopen("https://ziglang.org/download/index.json") as response:
    release = json.load(response)[version][f"{arch}-{system}"]
directory = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir())) / f"habush-zig-{version}"
directory.mkdir(parents=True, exist_ok=True)
archive = directory / release["tarball"].rsplit("/", 1)[1]
urllib.request.urlretrieve(release["tarball"], archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == release["shasum"]
if archive.suffix == ".zip":
    with zipfile.ZipFile(archive) as package:
        package.extractall(directory)
else:
    with tarfile.open(archive) as package:
        package.extractall(directory, filter="data")
tool_directory = directory / f"zig-{arch}-{system}-{version}"
if "GITHUB_PATH" in os.environ:
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as paths:
        paths.write(str(tool_directory) + "\n")
print(tool_directory)
