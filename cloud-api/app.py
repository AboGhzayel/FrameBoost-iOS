import os, shutil, subprocess, uuid
from pathlib import Path
from typing import Optional
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

DATA = Path(os.getenv("FRAMEBOOST_DATA", "/data/jobs"))
DATA.mkdir(parents=True, exist_ok=True)
MAX_BYTES = int(os.getenv("FRAMEBOOST_MAX_BYTES", str(500 * 1024 * 1024)))

app = FastAPI(title="FrameBoost Cloud API", version="0.1.0")

@app.get("/health")
def health():
    return {"status": "ok", "gpu": os.getenv("NVIDIA_VISIBLE_DEVICES", "unknown")}

@app.post("/v1/jobs")
async def create_job(
    video: UploadFile = File(...),
    targetFPS: int = Form(60),
    quality: float = Form(0.92),
    preserveAudio: bool = Form(True),
):
    if targetFPS not in (60, 120):
        raise HTTPException(400, "targetFPS must be 60 or 120")
    if not 0.1 <= quality <= 1.0:
        raise HTTPException(400, "quality must be between 0.1 and 1.0")

    job_id = uuid.uuid4().hex
    job_dir = DATA / job_id
    job_dir.mkdir(parents=True)
    source = job_dir / "input.mov"
    total = 0
    with source.open("wb") as out:
        while True:
            chunk = await video.read(1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_BYTES:
                shutil.rmtree(job_dir, ignore_errors=True)
                raise HTTPException(413, "Video exceeds the configured size limit")
            out.write(chunk)

    # Production hook: replace this placeholder with the GPU RIFE worker.
    # The API intentionally does not pretend that FFmpeg alone performs AI interpolation.
    return JSONResponse({
        "job_id": job_id,
        "status": "queued",
        "targetFPS": targetFPS,
        "quality": quality,
        "preserveAudio": preserveAudio,
        "message": "Job accepted. Attach a GPU RIFE worker to process queued jobs."
    }, status_code=202)

@app.get("/v1/jobs/{job_id}")
def job_status(job_id: str):
    job_dir = DATA / job_id
    if not job_dir.exists():
        raise HTTPException(404, "Job not found")
    return {"job_id": job_id, "status": "queued", "progress": 0.0}
