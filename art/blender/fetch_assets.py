#!/usr/bin/env python3
"""Download the third-party assets the Blender scripts use.

Reads art/blender/sources.json (pinned URL + sha256 per file), downloads
anything missing into art/third_party/blender/ (git-ignored), verifies the
checksum and unpacks zips next to them. Plain Python 3, no dependencies.

    python3 fetch_assets.py          # fetch + verify everything
    python3 fetch_assets.py --check  # only verify what is on disk
"""
import hashlib
import json
import os
import sys
import time
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
DEST = os.path.join(REPO, "art", "third_party", "blender")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(url, path, tries=5):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".part"
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "wordsmith-art-fetch/1.0"})
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:
                while True:
                    b = r.read(1 << 20)
                    if not b:
                        break
                    f.write(b)
            os.replace(tmp, path)
            return
        except Exception as e:  # flaky proxies / CDNs: retry with backoff
            print(f"    retry {i + 1}/{tries}: {e}")
            time.sleep(2 + 3 * i)
    raise RuntimeError(f"failed to download {url}")


def safe_extract(zpath, outdir):
    """Extract only image/texture/model data files, never outside outdir."""
    keep = (".jpg", ".jpeg", ".png", ".exr", ".gltf", ".glb", ".bin", ".obj",
            ".mtl", ".fbx", ".txt", ".md")
    os.makedirs(outdir, exist_ok=True)
    root = os.path.realpath(outdir)
    with zipfile.ZipFile(zpath) as z:
        for m in z.infolist():
            name = m.filename
            if m.is_dir() or not name.lower().endswith(keep):
                continue
            target = os.path.realpath(os.path.join(outdir, name))
            if not target.startswith(root + os.sep):
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(m) as src, open(target, "wb") as dst:
                dst.write(src.read())


def main():
    check_only = "--check" in sys.argv
    with open(os.path.join(HERE, "sources.json")) as f:
        sources = json.load(f)["assets"]
    bad = 0
    for s in sources:
        path = os.path.join(DEST, s["file"])
        if not os.path.exists(path):
            if check_only:
                print(f"MISSING {s['file']}")
                bad += 1
                continue
            print(f"fetch   {s['file']}")
            download(s["url"], path)
        digest = sha256(path)
        if digest != s["sha256"]:
            print(f"BAD SHA {s['file']}: {digest}")
            bad += 1
            continue
        if s.get("unzip_to") and not check_only:
            outdir = os.path.join(DEST, s["unzip_to"])
            if not os.path.isdir(outdir) or not os.listdir(outdir):
                safe_extract(path, outdir)
        print(f"ok      {s['file']}")
    if bad:
        sys.exit(f"{bad} asset(s) missing or failed verification")
    if not check_only:
        make_static_font()


def make_static_font():
    """Blender only loads a variable font's default instance, so cut a static
    Black (wght 900) Roboto Slab for the icon's 3D letter (needs fontTools)."""
    src = os.path.join(DEST, "fonts", "RobotoSlab-wght.ttf")
    dst = os.path.join(DEST, "fonts", "RobotoSlab-Black-static.ttf")
    if os.path.exists(dst) or not os.path.exists(src):
        return
    try:
        from fontTools.ttLib import TTFont
        from fontTools.varLib import instancer
    except ImportError:
        print("NOTE: pip install fonttools to build RobotoSlab-Black-static.ttf "
              "(icon.py falls back to Blender's built-in font)")
        return
    font = instancer.instantiateVariableFont(TTFont(src), {"wght": 900})
    font.save(dst)
    print(f"made    fonts/{os.path.basename(dst)}")


if __name__ == "__main__":
    main()
