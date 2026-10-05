"""Training samples: random runs of consecutive frames from the clips, cropped at the same place in every frame."""
import random
import numpy as np
import torch

import common


class Sequences(torch.utils.data.Dataset):
    """`length` frames in a row from a random clip, a `crop` x `crop` render-pixel window (and the output window over
    it). An epoch is `samples` such draws. `exposure_jitter`: the exposure varies by up to that many stops, so the net
    sees more brightness levels than the scenes have."""

    def __init__(self, clips, length=8, crop=96, samples=2000, exposure_jitter=1.0):
        self.runs = []   # (clip, first frame of a run of `length` consecutive frames with references)
        for clip in clips:
            fs = common.frames(clip)
            have = set(fs)
            self.runs += [(clip, f) for f in fs if all(f + k in have for k in range(length))]
        if not self.runs:
            raise SystemExit(f"no run of {length} frames with references in {len(clips)} clips")
        self.length, self.crop, self.samples, self.exposure_jitter = length, crop, samples, exposure_jitter
        first = self.runs[0]
        self.factor = common.row(*first)["outSize"][0] // common.row(*first)["size"][0]

    def __len__(self):
        return self.samples

    def __getitem__(self, _):
        clip, f0 = random.choice(self.runs)
        meta = common.row(clip, f0)
        w, h = meta["size"]
        c, k = self.crop, self.factor
        y, x = random.randrange(0, h - c + 1), random.randrange(0, w - c + 1)
        low, high = (y, x, c, c), (y * k, x * k, c * k, c * k)
        stops = random.uniform(-self.exposure_jitter, self.exposure_jitter)
        frames = []
        for f in range(f0, f0 + self.length):
            r = common.row(clip, f)
            arrays = {b: common.load(clip, f, b, low) for b in common.INPUTS}
            arrays["reference"] = common.load(clip, f, "reference", high)
            arrays["metalfx"] = common.load(clip, f, "metalfx", high)
            frames.append((r, arrays))
        stack = lambda b: torch.from_numpy(np.stack([a[b] for _, a in frames])).permute(0, 3, 1, 2).contiguous()
        sample = {b: stack(b) for b in common.INPUTS + ["reference", "metalfx"]}
        sample["jitter"] = torch.tensor([r["jitter"] for r, _ in frames], dtype=torch.float32)
        sample["exposure"] = torch.tensor([r["exposure"] * 2 ** stops for r, _ in frames], dtype=torch.float32)
        return sample   # each (T, C, h, w) or (T, ...)
