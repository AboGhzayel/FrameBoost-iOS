#!/usr/bin/env python3
"""Prepare a RIFE checkpoint for Core ML conversion.

This is a conversion utility, not a bundled model. It intentionally fails
loudly when the checkpoint/export environment is unavailable instead of
creating a fake .mlmodel.
"""
from pathlib import Path
import argparse


def main():
    p = argparse.ArgumentParser()
    p.add_argument("checkpoint", type=Path)
    p.add_argument("--output", type=Path, default=Path("FrameInterpolation.mlpackage"))
    args = p.parse_args()

    if not args.checkpoint.exists():
        raise SystemExit(f"Checkpoint not found: {args.checkpoint}")
    try:
        import torch
        import coremltools as ct
    except ImportError as exc:
        raise SystemExit("Install the conversion environment first: torch + coremltools") from exc

    # The exact RIFE architecture/export wrapper is model-version dependent.
    # Do not silently convert an incompatible checkpoint. A trained RIFE
    # wrapper exposing two RGB frames + timestep must be supplied here.
    raise SystemExit(
        "RIFE checkpoint detected, but no compatible export wrapper was supplied. "
        "Use the RIFE 4.25 export wrapper for this checkpoint, then trace/script "
        "the wrapper and call coremltools.convert(..., convert_to='mlprogram')."
    )


if __name__ == "__main__":
    main()
