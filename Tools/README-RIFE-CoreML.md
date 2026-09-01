# RIFE → Core ML

FrameBoost targets RIFE 4.25 for the 2× 30→60 FPS path.

## Important
The repository does **not** commit pretrained RIFE weights or a generated `.mlpackage` yet. The conversion script refuses to produce a placeholder model. This keeps the app honest: Core ML is only enabled when a real compatible model is bundled.

## Conversion environment

Use a pinned Python environment with PyTorch and `coremltools`. Export a RIFE 4.25 wrapper that accepts:

- `frame0`: RGB float tensor/image
- `frame1`: RGB float tensor/image
- `time`: interpolation timestep (normally 0.5 for 2×)

Then convert the exported model to an ML Program and validate it on representative 30 FPS clips before copying the resulting `FrameInterpolation.mlpackage` into the Xcode target.

## Runtime contract

The iOS runtime expects the bundled resource to be named `FrameInterpolation.mlmodelc` after Xcode compilation. If it is absent, FrameBoost must use its non-AI fallback and must not label the result as AI generated.

## Performance target

Primary target: 30 FPS → 60 FPS, one generated middle frame per source frame interval. Prefer Neural Engine/GPU-compatible Core ML execution and keep frame buffers bounded so 4K input does not accumulate in memory.
