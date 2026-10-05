"""Pictures of a dataset, to look at what the net learns from: per frame one PNG with, top row, the noisy light,
MetalFX's output and the reference (as the app shows them), and bottom row the guides (albedo, normals, motion).

    python3 view.py <dataset> [--scenes cornell,sun] [--out <dataset>/preview]
"""
import argparse, os
import numpy as np
from PIL import Image

import common


def resize(a, w, h):
    return np.asarray(Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)).resize((w, h), Image.NEAREST))


def main():
    p = argparse.ArgumentParser()
    p.add_argument("dataset")
    p.add_argument("--scenes", default="")
    p.add_argument("--out", default="")
    args = p.parse_args()
    out = args.out or os.path.join(args.dataset, "preview")
    os.makedirs(out, exist_ok=True)
    for clip in common.clip_dirs(args.dataset, [s for s in args.scenes.split(",") if s] or None):
        for f in common.frames(clip, need=()):
            r = common.row(clip, f)
            e, (w, h) = r["exposure"], r["size"]
            shown = lambda b: common.display(common.load(clip, f, b), e) if os.path.exists(common.array_path(clip, f, b)) \
                else np.zeros((h, w, 3))
            normal = common.load(clip, f, "normal")
            motion = common.load(clip, f, "motion")
            m = np.concatenate([np.clip(motion * 0.25 + 0.5, 0, 1), np.full((h, w, 1), 0.5)], 2)   # 0.5 grey: still
            top = [resize(shown(b), w, h) for b in ("color", "metalfx", "reference")]
            bottom = [resize(a, w, h) for a in (common.load(clip, f, "albedo"), normal[..., :3] * 0.5 + 0.5, m)]
            sheet = np.concatenate([np.concatenate(top, 1), np.concatenate(bottom, 1)], 0)
            Image.fromarray(sheet).save(os.path.join(out, f"{os.path.basename(clip)}-f{f:04d}.png"))
        print(os.path.basename(clip))


if __name__ == "__main__":
    main()
