# FrameBoost Cloud AI API

This folder defines the server contract used by the iOS app's optional **Cloud AI** mode.

## Contract

`POST /v1/interpolate` as `multipart/form-data`:

- `video`: source video file
- `options`: JSON object, for example `{ "targetFPS": 60, "preserveAudio": true, "quality": 0.92 }`

The service should return JSON:

```json
{ "outputURL": "https://your-cdn.example/output.mp4" }
```

The output URL must be HTTPS and should be short-lived/signed in production.

## Deployment

The iOS client intentionally contains **no API secret**. Configure the production HTTPS endpoint through managed app configuration by setting the `FrameBoostCloudEndpoint` UserDefaults key, or replace this with your preferred authenticated configuration layer before release.

A GPU provider is required for real cloud inference. The server can run RIFE or a newer interpolation pipeline and use FFmpeg for audio/container handling.

## Security checklist

- Authenticate every request.
- Limit upload size and duration.
- Use signed, expiring output URLs.
- Delete source/output files after a short retention period.
- Never put provider API keys in the iOS app.
- Use HTTPS only.
