#!/usr/bin/env python3
"""Export TensorForger RIFE v4 weights to a Core ML model for iOS 26.

The exported graph accepts NCHW float32 [1,6,H,W] RGB tensors in [0,1] and
returns [1,3,H,W]. H/W are intended to be multiples of 32. The workflow
keeps the source weights out of git and downloads the pinned MIT-licensed
weights at build time.
"""
from pathlib import Path
import subprocess
import sys

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

    # RIFE's flow grid and pyramid are shape dependent, so export a practical
    # fixed 256x256 graph first. Runtime performs tiled interpolation and blends
    # tiles with overlap; this is much safer on iPhone memory than a giant 4K tensor.
    example = torch.zeros((1, 6, 256, 256), dtype=torch.float32)
    traced = torch.jit.trace(model, example, strict=False)
    traced = torch.jit.freeze(traced)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(name="frames", shape=(1, 6, 256, 256), dtype=ct.models.datatypes.ArrayDataType.FLOAT32)],
        outputs=[ct.TensorType(name="frame", dtype=ct.models.datatypes.ArrayDataType.FLOAT32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS18,
    )
    mlmodel.author = "FrameBoost / RIFE v4"
    mlmodel.short_description = "RIFE 2x frame interpolation; 6-channel RGB pair to intermediate RGB frame"
    mlmodel.version = "4.25-frameboost-1"
    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists():
        import shutil
        shutil.rmtree(OUT)
    mlmodel.save(str(OUT))
    print(f"Wrote {OUT}")


if __name__ == "__main__":
    main()
