#!/usr/bin/env python3
"""Download every third-party art/audio/font source used by Wordsmith.

Reads the pinned source list in ``art/sources.json`` and downloads each file
into ``art/third_party/<pack>/`` (git-ignored), verifying its SHA-256. Zip
packs are extracted next to the archive, and every pack gets a ``LICENSE``
file (the pack's own licence text, or the official licence text) plus a
``SOURCE.txt`` describing where it came from.

Standard library only, so it runs anywhere Python 3.9+ is installed:

    python3 art/fetch.py                 # fetch everything (skips verified files)
    python3 art/fetch.py --only game-icons kenney-impact-sounds
    python3 art/fetch.py --force         # re-download even if present
    python3 art/fetch.py --list          # show packs and exit

HTTPS proxies are honoured through the usual HTTPS_PROXY environment variable.
A file whose checksum does not match is never kept: the script stops with an
error so a changed upstream file can be reviewed (licence included) before
``sources.json`` is updated.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ART = Path(__file__).resolve().parent
SOURCES = ART / "sources.json"
THIRD_PARTY = ART / "third_party"
USER_AGENT = "Mozilla/5.0 (compatible; WordsmithAssetFetch/1.0)"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def http_get(url: str, dest: Path, attempts: int = 4) -> None:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp, dest.open("wb") as out:
                shutil.copyfileobj(resp, out)
            return
        except urllib.error.HTTPError:
            raise  # a real HTTP answer (404, 403...): retrying won't help
        except (urllib.error.URLError, ConnectionError, TimeoutError, OSError) as exc:
            if attempt == attempts:
                raise
            print(f"  retry   {url} ({exc}); attempt {attempt + 1}/{attempts}")
            time.sleep(2 * attempt)


def discover_zip(page_url: str, basename: str) -> str | None:
    """Find a fresh download link on an asset page (Kenney re-hashes media URLs)."""
    fd, name = tempfile.mkstemp(suffix=".html")
    os.close(fd)
    tmp = Path(name)
    try:
        http_get(page_url, tmp)
        html = tmp.read_text("utf-8", errors="replace")
    finally:
        tmp.unlink(missing_ok=True)
    for link in re.findall(r"""https?://[^"'\s<>]+\.zip""", html):
        if link.rsplit("/", 1)[-1] == basename:
            return link
    return None


def safe_dest(base: Path, rel: str) -> Path:
    dest = (base / rel).resolve()
    if base.resolve() not in dest.parents and dest != base.resolve():
        raise RuntimeError(f"refusing to write outside {base}: {rel}")
    return dest


def fetch_file(pack_dir: Path, f: dict, force: bool) -> Path:
    dest = safe_dest(pack_dir, f["name"])
    if dest.exists() and not force and sha256_file(dest) == f["sha256"]:
        print(f"  ok      {f['name']}")
        return dest
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    url = f["url"]
    try:
        http_get(url, tmp)
    except urllib.error.HTTPError as err:
        if not f.get("discover_from") or err.code not in (403, 404, 410):
            raise
        fresh = discover_zip(f["discover_from"], url.rsplit("/", 1)[-1])
        if not fresh:
            raise RuntimeError(f"{url} -> HTTP {err.code}, and no replacement link on {f['discover_from']}")
        print(f"  note    pinned URL gone (HTTP {err.code}); trying {fresh}\n"
              f"          update 'url' in sources.json if the checksum matches")
        http_get(fresh, tmp)
    got = sha256_file(tmp)
    if got != f["sha256"]:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"checksum mismatch for {f['name']} from {url}\n"
                           f"  expected {f['sha256']}\n  got      {got}\n"
                           "The upstream file changed: review it (and its licence) before updating sources.json.")
    tmp.replace(dest)
    print(f"  fetched {f['name']} ({dest.stat().st_size:,} bytes)")
    return dest


def extract_zip(archive: Path, pack_dir: Path, sha: str) -> None:
    marker = pack_dir / f".extracted-{sha[:16]}"
    if marker.exists():
        return
    with zipfile.ZipFile(archive) as zf:
        for info in zf.infolist():
            target = safe_dest(pack_dir, info.filename)
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with zf.open(info) as src, target.open("wb") as out:
                shutil.copyfileobj(src, out)
    marker.write_text(archive.name + "\n")
    print(f"  extracted {archive.name}")


def write_source_txt(pack_dir: Path, pack: dict) -> None:
    lines = [
        f"Pack:      {pack['title']}",
        f"Author:    {pack['author']}",
        f"Licence:   {pack['licence']} ({pack['licence_url']})",
        f"Page:      {pack['page']}",
        f"Retrieved: {pack['retrieved']}",
        "",
        "Files (URL, SHA-256):",
    ]
    for f in pack["files"]:
        lines.append(f"  {f['name']}\n    {f['url']}\n    sha256 {f['sha256']}")
    (pack_dir / "SOURCE.txt").write_text("\n".join(lines) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="+", metavar="PACK", help="fetch only these pack ids")
    ap.add_argument("--force", action="store_true", help="re-download files even if already verified")
    ap.add_argument("--list", action="store_true", help="list packs and exit")
    args = ap.parse_args()

    packs = json.loads(SOURCES.read_text())["packs"]
    if args.list:
        for p in packs:
            print(f"{p['id']:26} {p['licence']:10} {len(p['files']):3} file(s)  {p['page']}")
        return 0
    if args.only:
        unknown = set(args.only) - {p["id"] for p in packs}
        if unknown:
            ap.error(f"unknown pack(s): {', '.join(sorted(unknown))}")
        packs = [p for p in packs if p["id"] in args.only]

    failures = 0
    for pack in packs:
        print(f"[{pack['id']}] {pack['title']} - {pack['licence']}")
        pack_dir = THIRD_PARTY / pack["id"]
        pack_dir.mkdir(parents=True, exist_ok=True)
        try:
            for f in pack["files"]:
                path = fetch_file(pack_dir, f, args.force)
                if f.get("extract"):
                    extract_zip(path, pack_dir, f["sha256"])
            member = pack.get("licence_member")
            if member:
                shutil.copyfile(safe_dest(pack_dir, member), pack_dir / "LICENSE")
            elif not (pack_dir / "LICENSE").exists():
                lic = [f for f in pack["files"] if f.get("licence_text")]
                if lic:
                    shutil.copyfile(safe_dest(pack_dir, lic[0]["name"]), pack_dir / "LICENSE")
            if not (pack_dir / "LICENSE").exists():
                raise RuntimeError("no licence text for this pack")
            write_source_txt(pack_dir, pack)
        except Exception as exc:  # keep going so one bad pack doesn't hide the others
            failures += 1
            print(f"  ERROR   {exc}", file=sys.stderr)
    if failures:
        print(f"\n{failures} pack(s) failed", file=sys.stderr)
        return 1
    print(f"\nAll sources present and verified in {os.path.relpath(THIRD_PARTY)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
