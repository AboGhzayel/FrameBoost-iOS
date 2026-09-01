# RIFE 4.25 for FrameBoost

FrameBoost uses Practical-RIFE 4.25 as the planned 2x interpolation engine for 30 -> 60 FPS.

Upstream model: https://github.com/hzwer/Practical-RIFE

## Important

The upstream checkpoint is distributed separately from the source repository. Do not commit downloaded weights blindly. The GitHub Actions workflow should download a pinned, license-compatible checkpoint, verify its SHA-256, and convert it during CI.

## Conversion target

1. Download the official Practical-RIFE 4.25 checkpoint (`flownet.pkl`) from the upstream model release.
2. Convert/trace the model with a pinned Python/PyTorch environment.
3. Export a Core ML model with a fixed, validated tensor contract.
4. Run Core ML model validation against known RIFE reference frames.
5. Compile the validated `.mlmodel` to `.mlmodelc` with `xcrun coremlcompiler` on the macOS GitHub runner.
6. Copy the compiled model into the app bundle/resources.
7. Run an iOS build and unit validation before packaging the IPA.

## Model contract

The Swift integration must not guess input/output names or tensor layouts. The conversion step must emit a small JSON manifest containing the exact model inputs, outputs, shapes, image formats, and timestep convention. `RIFEEngine.swift` should be updated from that manifest after validation.

## Memory policy

For 4K input, start with a 0.5 pyramid scale or tiled/chunked inference. Never keep the complete decoded video in memory. Process one adjacent frame pair at a time and release intermediate tensors before reading the next pair.

## Licensing

Practical-RIFE is MIT licensed according to its upstream repository. Verify the exact checkpoint license/redistribution terms before embedding weights in a distributed IPA.