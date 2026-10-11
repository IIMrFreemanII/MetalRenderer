"""Training samples: random runs of consecutive frames from the clips, cropped at the same place in every frame."""
import os, random
import numpy as np
import torch

import common

COLOURS = ["color", "albedo", "specular", "diffuse", "specularlight", "reference", "metalfx"]   # rgb, permuted together


class Sequences(torch.utils.data.Dataset):
    """`length` frames in a row from a random clip, a `crop` x `crop` render-pixel window (and the output window over
    it). An epoch is `samples` such draws. `exposure_jitter`: the exposure varies by up to that many stops, so the net
    sees more brightness levels than the scenes have. `inputs`: the arrays to load (common.INPUTS or INPUTS_V2).
    `augment`: each sample mirrored, turned and its colour channels shuffled at random (the same for all its frames),
    so the net sees more scenes than there are; the motion and the jitter turn with the picture (the normals are in
    world space and stay as they are). `refs_last`: a run needs references only for its last this many frames (held
    clips: the frames before only build the history); the others' are NaN, which the loss leaves out."""

    def __init__(self, clips, length=8, crop=96, samples=2000, exposure_jitter=1.0, inputs=common.INPUTS, augment=False,
                 refs_last=None):
        self.runs = []   # (clip, first frame of a run of `length` consecutive frames with references)
        ref_from = length - (refs_last or length)
        for clip in clips:
            have, refs = set(common.frames(clip, need=())), set(common.frames(clip))
            self.runs += [(clip, f) for f in sorted(have) if all(f + k in have for k in range(length))
                          and all(f + k in refs for k in range(ref_from, length))]
        if not self.runs:
            raise SystemExit(f"no run of {length} frames with references in {len(clips)} clips")
        self.length, self.crop, self.samples, self.exposure_jitter = length, crop, samples, exposure_jitter
        self.inputs, self.augment = list(inputs), augment
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
            arrays = {b: common.load(clip, f, b, low) for b in self.inputs}
            arrays["reference"] = common.load(clip, f, "reference", high) if os.path.exists(common.array_path(clip, f, "reference")) \
                else np.full((c * k, c * k, 3), np.nan, np.float32)
            arrays["metalfx"] = common.load(clip, f, "metalfx", high)
            frames.append((r, arrays))
        stack = lambda b: torch.from_numpy(np.stack([a[b] for _, a in frames])).permute(0, 3, 1, 2).contiguous()
        sample = {b: stack(b) for b in self.inputs + ["reference", "metalfx"]}
        sample["jitter"] = torch.tensor([r["jitter"] for r, _ in frames], dtype=torch.float32)
        sample["exposure"] = torch.tensor([r["exposure"] * 2 ** stops for r, _ in frames], dtype=torch.float32)
        if self.augment:
            augment(sample)
        return sample   # each (T, C, h, w) or (T, ...)


def augment(sample):
    """One of the 8 mirror and quarter-turn images of `sample`, in place, and its colour channels in a random order.
    Mirroring x negates the motion's and the jitter's x; swapping x and y swaps their components."""
    images = [k for k, v in sample.items() if v.dim() == 4]
    flip_x, flip_y, swap = random.random() < 0.5, random.random() < 0.5, random.random() < 0.5
    for k in images:
        v = sample[k]
        if swap:
            v = v.transpose(-1, -2)
        if flip_x:
            v = v.flip(-1)
        if flip_y:
            v = v.flip(-2)
        sample[k] = v.contiguous()
    vectors = [sample["motion"], sample["jitter"]]   # (T, 2, h, w) and (T, 2)
    for i, v in enumerate(vectors):
        if swap:
            v = v[:, [1, 0]]
        sign = torch.tensor([-1.0 if flip_x else 1.0, -1.0 if flip_y else 1.0])
        vectors[i] = v * (sign.view(1, 2, 1, 1) if v.dim() == 4 else sign.view(1, 2))
    sample["motion"], sample["jitter"] = vectors[0].contiguous(), vectors[1].contiguous()
    order = torch.randperm(3)
    for k in COLOURS:
        if k in sample:
            sample[k] = sample[k][:, order].contiguous()
    if "extra" in sample:
        sample["extra"] = torch.cat([sample["extra"][:, order], sample["extra"][:, 3:]], 1).contiguous()
