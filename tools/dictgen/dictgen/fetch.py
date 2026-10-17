"""`fetch`: download the pinned Open English WordNet release and its licence files.

Everything goes to the raw directory (default data/raw/, git-ignored). Each
file's SHA-256 is checked against the value recorded here, so a changed
upstream file is never used without review.
"""

from __future__ import annotations

import hashlib
import os
import urllib.request

EDITION = "2024"
SOURCE_NAME = f"Open English WordNet {EDITION}"
LICENSE_NAME = "CC BY 4.0"
HOME_URL = "https://github.com/globalwordnet/english-wordnet"
XML_NAME = f"english-wordnet-{EDITION}.xml.gz"

# name -> (url, sha256 of the file as fetched on 2026-10-17)
SOURCES = {
    XML_NAME: (
        f"{HOME_URL}/releases/download/{EDITION}-edition/{XML_NAME}",
        "e1f633b0a93758cae34ea27c44c4dad310a8af2467b155f99dd6673af697e875",
    ),
    "LICENSE.md": (
        f"https://raw.githubusercontent.com/globalwordnet/english-wordnet/{EDITION}-edition/LICENSE.md",
        "5d02a553699c4841d8b33cc5a1313cff1f96264e36e9dc98be829dfc94a6cc73",
    ),
    "WNDB_License.txt": (
        f"https://raw.githubusercontent.com/globalwordnet/english-wordnet/{EDITION}-edition/WNDB_License.txt",
        "df30ec18fbabcdaf031b79ea026d3e6b959010cffe6dd7be9ac137822175b904",
    ),
}


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url: str, dest: str) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": "wordsmith-dictgen/1"})
    tmp = dest + ".part"
    with urllib.request.urlopen(req, timeout=300) as resp, open(tmp, "wb") as out:
        while True:
            chunk = resp.read(1 << 16)
            if not chunk:
                break
            out.write(chunk)
    os.replace(tmp, dest)


def verify(raw_dir: str) -> list[str]:
    """Problems with the files in raw_dir (missing or changed); empty when all is well."""
    problems = []
    for name, (_url, expected) in SOURCES.items():
        path = os.path.join(raw_dir, name)
        if not os.path.exists(path):
            problems.append(f"{path} missing (run `python3 -m dictgen fetch`)")
        elif sha256_file(path) != expected:
            problems.append(f"{path}: sha256 {sha256_file(path)} != pinned {expected}")
    return problems


def fetch(raw_dir: str, force: bool = False, log=print) -> bool:
    os.makedirs(raw_dir, exist_ok=True)
    for name, (url, expected) in SOURCES.items():
        dest = os.path.join(raw_dir, name)
        if force or not os.path.exists(dest) or sha256_file(dest) != expected:
            log(f"downloading {url}")
            download(url, dest)
        digest = sha256_file(dest)
        if digest != expected:
            log(f"CHECKSUM CHANGED for {name}: got {digest}, pinned {expected}.\n"
                "Review the new file (and its licence) before updating SOURCES in dictgen/fetch.py.")
            return False
        log(f"ok {name} ({os.path.getsize(dest):,} bytes)")
    return True
