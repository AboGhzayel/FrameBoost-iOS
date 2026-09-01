# FrameBoost Architecture

## Pipeline
1. `VideoPicker` imports a local video into temporary storage.
2. `FrameBoostModel` owns UI state and processing lifecycle.
3. `VideoProcessor` coordinates AVFoundation processing and progress/cancellation.
4. `FrameInterpolationEngine` defines the interpolation boundary.
5. `AVFoundationInterpolationEngine` is the safe fallback/export implementation.

## Interpolation roadmap
The engine protocol intentionally isolates frame generation. A future motion-compensated implementation can generate intermediate frames from adjacent source frames, while keeping the UI and export lifecycle unchanged.

## Output policy
2x and 4x are supported as requested settings. Output is capped at 120 FPS in configuration so extreme source rates do not create unsupported targets.
