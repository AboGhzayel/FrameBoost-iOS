#!/usr/bin/env python3
"""Export the pinned TensorForger RIFE v4 model to Core ML.

The generated model is a fixed 256x256 tile interpolator. Runtime code is
responsible for overlap tiling and reconstruction so 4K clips stay within
mobile memory limits.
"""
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np
import coremltools as ct
import torch
from safetensors.torch import load_file

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".rife-build"
SRC = WORK / "RIFE-safetensors"
OUT = ROOT / "FrameBoost" / "RIFE_4_25.mlpackage"
REF = "78a62b7c2dd910536432d6c2c3a25e76f14fbf78"
REPO = "https://huggingface.co/TensorForger/RIFE-safetensors"


def checkout_source() -> None:
    WORK.mkdir(exist_ok=True)
    if not SRC.exists():
        subprocess.run(["git", "clone", "--depth", "1", REPO, str(SRC)], check=True)
    else:
        subprocess.run(["git", "-C", str(SRC), "fetch", "--depth", "1", "origin", REF], check=True)
        subprocess.run(["git", "-C", str(SRC), "checkout", REF], check=True)


def main() -> None:
    checkout_source()
    sys.path.insert(0, str(SRC))
    from interpolation_model import IFNet

    model = IFNet().eval().cpu()
    state = load_file(str(SRC / "flownet.safetensors"), device="cpu")
    model.load_state_dict(state, strict=True)

    example = torch.zeros((1, 6, 256, 256), dtype=torch.float32)
    with torch.no_grad():
        traced = torch.jit.trace(model, example, strict=False)
    traced = torch.jit.freeze(traced)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="frames", shape=(1, 6, 256, 256), dtype=np.float32)],
        outputs=[ct.TensorType(name="frame", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.author = "FrameBoost / RIFE v4.25"
    mlmodel.short_description = "RIFE 2x frame interpolation; 6-channel RGB pair to intermediate RGB frame"
    mlmodel.version = "4.25-frameboost-1"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        shutil.rmtree(OUT)
    mlmodel.save(str(OUT))
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
