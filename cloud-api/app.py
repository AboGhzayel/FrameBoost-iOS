import os, shutil, threading, uuid
from pathlib import Path
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse, JSONResponse
from worker import mux_audio, run_rife

DATA = Path(os.getenv("FRAMEBOOST_DATA", "/data/jobs"))
DATA.mkdir(parents=True, exist_ok=True)
MAX_BYTES = int(os.getenv("FRAMEBOOST_MAX_BYTES", str(500 * 1024 * 1024)))

app = FastAPI(title="FrameBoost Cloud API", version="0.2.0")

@app.get("/health")
def health():
    return {"status": "ok", "gpu": os.getenv("NVIDIA_VISIBLE_DEVICES", "unknown")}

def process_job(job_id: str, target_fps: int, preserve_audio: bool):
    job_dir = DATA / job_id
    source = job_dir / "input.mov"
    silent = job_dir / "interpolated.mp4"
    final = job_dir / "output.mp4"
    try:
        (job_dir / "status").write_text("processing")
        run_rife(source, silent, target_fps)
        if preserve_audio:
            mux_audio(source, silent, final)
        else:
            shutil.copy2(silent, final)
        (job_dir / "status").write_text("completed")
    except Exception as exc:
        (job_dir / "status").write_text("failed")
        (job_dir / "error").write_text(str(exc))

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
    (job_dir / "status").write_text("queued")
    threading.Thread(target=process_job, args=(job_id, targetFPS, preserveAudio), daemon=True).start()
    return JSONResponse({"job_id": job_id, "status": "queued", "targetFPS": targetFPS, "quality": quality, "preserveAudio": preserveAudio}, status_code=202)

@app.get("/v1/jobs/{job_id}")
def job_status(job_id: str):
    job_dir = DATA / job_id
    if not job_dir.exists():
        raise HTTPException(404, "Job not found")
    status = (job_dir / "status").read_text().strip() if (job_dir / "status").exists() else "queued"
    payload = {"job_id": job_id, "status": status, "progress": 1.0 if status == "completed" else 0.0}
    if status == "failed" and (job_dir / "error").exists():
        payload["error"] = (job_dir / "error").read_text()
    if status == "completed":
        payload["outputURL"] = f"/v1/jobs/{job_id}/output"
    return payload

@app.get("/v1/jobs/{job_id}/output")
def output(job_id: str):
    path = DATA / job_id / "output.mp4"
    if not path.exists():
        raise HTTPException(404, "Output is not ready")
    return FileResponse(path, media_type="video/mp4", filename="FrameBoost.mp4")
