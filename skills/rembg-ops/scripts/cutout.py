#!/usr/bin/env python3
"""Transparent-PNG cutouts for flat illustration / sticker / cartoon art.

rembg's ML models are the default engine, but they DROP pale/low-salience
subjects and mis-handle baked drop-shadows on flat-colour art. This script wraps
rembg (isnet-anime) with a deterministic fallback ladder that exploits the one
thing flat sticker art always has — a single flat background colour and a sealing
outline — so the hard cases (pale UFO, near-white moon, translucent cup, baked
offset shadow) come out clean without regenerating the source pixels.

Methods (see references/cutout-methods.md for when each applies):
  rembg      ML segmentation (isnet-anime) — flat cartoon/outlined art, ~90%.
  colorkey   flood-fill the flat bg from the corners; keep everything the outline
             seals off, fully opaque. Recovers subjects rembg drops AND forces
             translucent subjects opaque. Deterministic; ignores subject colour.
  auto       rembg first; if the subject silhouette collapses (coverage < --min-cov)
             fall back to colorkey. The default.
Post-processing (opt-in, for baked shadows rembg keeps as a ghost):
  --flatten-alpha T      binarise alpha at T — drops semi-transparent shadow ghosts.
  --strip-offset-shadow  colour-aware: drop dark pixels not hugging a coloured fill
                         (removes an opaque baked offset shadow, keeps the outline).

Usage:   cutout.py INPUT... [--out DIR] [--method auto|rembg|colorkey]
                    [--model NAME] [--tol N] [--min-cov F]
                    [--flatten-alpha T] [--strip-offset-shadow] [--contact-sheet]
                    [--json]
Input:   image path(s), a directory, or a glob (argv only; no stdin).
Output:  stdout = per-image result rows (plain TSV, or --json envelope). Data only.
Stderr:  progress, backend notices, warnings, errors.
Exit:    0 all ok, 2 usage, 3 input not found, 5 no imaging backend
         (Pillow/numpy missing), 10 one or more images failed / collapsed.

Examples:
  cutout.py avatar.png --out cutouts/
  cutout.py "src/*.png" --out cutouts/ --contact-sheet
  cutout.py moon.png --method colorkey --out cutouts/        # pale subject
  cutout.py hero.png --flatten-alpha 170 --out cutouts/      # shadow ghost
  cutout.py crystal.png --strip-offset-shadow --out cutouts/ # opaque baked shadow
  cutout.py "*.png" --out cutouts/ --json | jq '.data[] | select(.coverage < 0.12)'
"""
from __future__ import annotations

import argparse
import glob as globmod
import json
import os
import sys

EXIT_OK, EXIT_USAGE, EXIT_NOINPUT, EXIT_NOBACKEND, EXIT_FAIL = 0, 2, 3, 5, 10


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def _need_backend():
    try:
        import numpy  # noqa: F401
        from PIL import Image  # noqa: F401
    except Exception as e:  # pragma: no cover - env-dependent
        log(f"error: Pillow + numpy are required ({e}). pip/uv install pillow numpy")
        sys.exit(EXIT_NOBACKEND)


def collect_inputs(patterns):
    files = []
    for p in patterns:
        if os.path.isdir(p):
            files += sorted(globmod.glob(os.path.join(p, "*.png")))
        elif any(ch in p for ch in "*?["):
            files += sorted(globmod.glob(p))
        else:
            files.append(p)
    missing = [f for f in files if not os.path.isfile(f)]
    return files, missing


# ── methods ────────────────────────────────────────────────────────────────
def _bg_color(arr, k=12):
    import numpy as np
    corners = np.concatenate([
        arr[:k, :k].reshape(-1, 3), arr[:k, -k:].reshape(-1, 3),
        arr[-k:, :k].reshape(-1, 3), arr[-k:, -k:].reshape(-1, 3),
    ])
    return np.median(corners, axis=0)


def _flood_bg_mask(near):
    """Pixels near-bg AND reachable from the image border → background.
    Keeps bg-coloured regions *inside* the subject (they don't touch an edge)."""
    import numpy as np
    try:
        from scipy import ndimage
        lab, _ = ndimage.label(near)
        border = np.concatenate([lab[0, :], lab[-1, :], lab[:, 0], lab[:, -1]])
        keep = np.zeros(lab.max() + 1, bool)
        keep[np.unique(border[border > 0])] = True
        return keep[lab]
    except Exception:
        from collections import deque
        h, w = near.shape
        vis = np.zeros((h, w), bool)
        dq = deque()
        for x in range(w):
            for y in (0, h - 1):
                if near[y, x] and not vis[y, x]:
                    vis[y, x] = True; dq.append((y, x))
        for y in range(h):
            for x in (0, w - 1):
                if near[y, x] and not vis[y, x]:
                    vis[y, x] = True; dq.append((y, x))
        while dq:
            y, x = dq.popleft()
            for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                ny, nx = y + dy, x + dx
                if 0 <= ny < h and 0 <= nx < w and not vis[ny, nx] and near[ny, nx]:
                    vis[ny, nx] = True; dq.append((ny, nx))
        return vis


def method_colorkey(img, tol):
    import numpy as np
    from PIL import Image
    rgb = img.convert("RGB")
    arr = np.asarray(rgb).astype(np.int16)
    near = np.abs(arr - _bg_color(arr)).sum(axis=2) < tol
    bg = _flood_bg_mask(near)
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    return Image.fromarray(np.dstack([np.asarray(rgb), alpha]))


def method_rembg(img, model):
    try:
        from rembg import remove, new_session
    except Exception as e:
        raise RuntimeError(f"rembg not available ({e}); use --method colorkey") from e
    return remove(img.convert("RGBA"), session=new_session(model))


def _dilate(mask, r):
    import numpy as np
    m = mask.copy()
    for _ in range(r):
        d = np.zeros_like(m)
        d[1:, :] |= m[:-1, :]; d[:-1, :] |= m[1:, :]
        d[:, 1:] |= m[:, :-1]; d[:, :-1] |= m[:, 1:]
        m = m | d
    return m


def post_flatten_alpha(cut, T):
    import numpy as np
    from PIL import Image
    arr = np.array(cut.convert("RGBA"))
    arr[:, :, 3] = np.where(arr[:, :, 3] >= T, 255, 0).astype(np.uint8)
    return Image.fromarray(arr)


def post_strip_offset_shadow(img, tol, dark=80, dilate=7):
    """Key the bg, then drop dark pixels that don't hug a coloured fill — i.e. an
    opaque baked offset shadow — while keeping the subject's own outline."""
    import numpy as np
    from PIL import Image
    rgb = img.convert("RGB")
    arr = np.asarray(rgb).astype(np.int16)
    near = np.abs(arr - _bg_color(arr)).sum(axis=2) < tol
    fg = ~_flood_bg_mask(near)
    gray = np.asarray(rgb).astype(np.float32).mean(axis=2)
    is_dark = gray < dark
    colored = fg & (~is_dark)
    keep = colored | (is_dark & _dilate(colored, dilate))
    alpha = np.where(keep, 255, 0).astype(np.uint8)
    return Image.fromarray(np.dstack([np.asarray(rgb), alpha]))


def coverage(cut):
    import numpy as np
    return float((np.array(cut.convert("RGBA"))[:, :, 3] > 16).mean())


def checker(w, h, s=16):
    from PIL import Image
    import numpy as np
    yy, xx = np.mgrid[0:h, 0:w]
    board = ((xx // s + yy // s) % 2).astype(np.uint8)
    rgb = np.where(board[..., None], 185, 225).astype(np.uint8).repeat(3, axis=2)
    return Image.fromarray(rgb, "RGB")


# ── driver ───────────────────────────────────────────────────────────────
def process_one(path, args):
    from PIL import Image
    img = Image.open(path)
    method = args.method
    if method == "colorkey":
        cut = method_colorkey(img, args.tol); used = "colorkey"
    elif method == "rembg":
        cut = method_rembg(img, args.model); used = f"rembg:{args.model}"
    else:  # auto
        try:
            cut = method_rembg(img, args.model); used = f"rembg:{args.model}"
            if coverage(cut) < args.min_cov:
                log(f"  {os.path.basename(path)}: rembg collapsed → colorkey")
                cut = method_colorkey(img, args.tol); used = "colorkey(fallback)"
        except RuntimeError as e:
            log(f"  {e}"); cut = method_colorkey(img, args.tol); used = "colorkey(no-rembg)"
    if args.strip_offset_shadow:
        cut = post_strip_offset_shadow(img, args.tol); used += "+strip-shadow"
    if args.flatten_alpha is not None:
        cut = post_flatten_alpha(cut, args.flatten_alpha); used += f"+flatten@{args.flatten_alpha}"
    return cut, used


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("inputs", nargs="*")
    ap.add_argument("--out", default=".")
    ap.add_argument("--method", choices=("auto", "rembg", "colorkey"), default="auto")
    ap.add_argument("--model", default="isnet-anime")
    ap.add_argument("--tol", type=int, default=42, help="colorkey bg match tolerance (sum of 3 channels)")
    ap.add_argument("--min-cov", type=float, default=0.10, help="auto: rembg alpha coverage below this → colorkey")
    ap.add_argument("--flatten-alpha", type=int, default=None, metavar="T")
    ap.add_argument("--strip-offset-shadow", action="store_true")
    ap.add_argument("--contact-sheet", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    args = ap.parse_args(argv)

    if args.help:
        print(__doc__); return EXIT_OK
    if not args.inputs:
        log("usage: cutout.py INPUT... [--out DIR] [--method ...]  (see --help)")
        return EXIT_USAGE

    _need_backend()
    files, missing = collect_inputs(args.inputs)
    if missing:
        log(f"error: input not found: {missing[0]}")
        return EXIT_NOINPUT
    if not files:
        log("error: no input images matched")
        return EXIT_NOINPUT

    os.makedirs(args.out, exist_ok=True)
    results, failed, cuts = [], 0, []
    for path in files:
        name = os.path.splitext(os.path.basename(path))[0]
        try:
            cut, used = process_one(path, args)
            cov = coverage(cut)
            op = os.path.join(args.out, f"{name}.png")
            cut.save(op)
            cuts.append((name, cut))
            low = cov < args.min_cov
            failed += low
            results.append({"name": name, "output": op, "method": used,
                            "coverage": round(cov, 4), "ok": not low})
            log(f"  {'WARN' if low else 'ok'}  {name:16s} {used:24s} cov {cov*100:5.1f}%")
        except Exception as e:
            failed += 1
            results.append({"name": name, "input": path, "method": args.method,
                            "coverage": 0.0, "ok": False, "error": str(e)})
            log(f"  FAIL  {name}: {e}")

    if args.contact_sheet and cuts:
        import math
        from PIL import Image, ImageDraw, ImageFont
        cell, cols, pad, lab = 200, 6, 8, 20
        rows = math.ceil(len(cuts) / cols)
        grid = Image.new("RGB", (cols * cell + (cols + 1) * pad,
                                 rows * (cell + lab) + (rows + 1) * pad), (255, 255, 255))
        d = ImageDraw.Draw(grid)
        try:
            font = ImageFont.load_default(14)
        except Exception:
            font = ImageFont.load_default()
        for i, (nm, cut) in enumerate(cuts):
            r, c = divmod(i, cols)
            x, y = pad + c * (cell + pad), pad + r * (cell + lab + pad)
            ch = checker(cell, cell); ch.paste(cut.convert("RGBA").resize((cell, cell)), (0, 0), cut.convert("RGBA").resize((cell, cell)))
            grid.paste(ch, (x, y)); d.text((x + 4, y + cell + 3), nm, fill=(20, 20, 20), font=font)
        sheet = os.path.join(args.out, "00_contact_sheet.png")
        grid.save(sheet)
        log(f"  contact sheet → {sheet}")

    status = EXIT_FAIL if failed else EXIT_OK
    if args.json:
        env = {"ok": status == EXIT_OK, "data": results,
               "summary": {"total": len(files), "failed": failed}}
        if status != EXIT_OK:
            env["error"] = {"code": "cutout_failed", "message": f"{failed} image(s) failed or collapsed"}
        print(json.dumps(env))
    else:
        for r in results:
            print(f"{r['name']}\t{r.get('output', r.get('input',''))}\t{r['method']}\t{r['coverage']}\t{'ok' if r['ok'] else 'FAIL'}")
    return status


if __name__ == "__main__":
    sys.exit(main())
