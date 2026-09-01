# RIFE 4.25 for FrameBoost

FrameBoost uses Practical-RIFE 4.25 as the planned 2x interpolation engine for 30 -> 60 FPS.

Upstream model: https://github.com/hzwer/Practical-RIFE

## CI pipeline

The model must be treated as a build artifact, not a placeholder. GitHub Actions should:

1. Pin the exact Practical-RIFE source revision and checkpoint URL.
2. Verify the checkpoint SHA-256 before conversion.
3. Install a pinned Python/PyTorch/Core ML Tools environment.
4. Convert/trace `flownet.pkl` to Core ML.
5. Validate the converted model against reference frame pairs.
6. Emit a model manifest containing exact input/output names, shapes, layouts, normalization and timestep convention.
7. Compile the validated `.mlmodel` on the macOS runner.
8. Copy the compiled `RIFE_4_25.mlmodelc` into the iOS app bundle.
9. Build the IPA and run a smoke test that confirms the model is present.

Do not silently substitute a fake model or guessed tensor schema.

## Runtime contract

`RIFEEngine` receives two adjacent frames and must return exactly one intermediate frame. It must not change the output cadence outside the 2x interpolation path. For native 60 FPS input, RIFE is bypassed.

## Memory policy

For 4K input, use downscaled/tiled inference and process one adjacent pair at a time. Release intermediate tensors before decoding the next pair. If the model cannot fit the available memory, fall back to the safe non-AI path rather than crashing.

## Licensing

Practical-RIFE is MIT licensed according to its upstream repository. Verify the exact checkpoint license/redistribution terms before embedding weights in a distributed IPA.