import os, subprocess, tempfile
from pathlib import Path


def run_rife(input_path: Path, output_path: Path, target_fps: int) -> None:
    """GPU worker entry point.

    The container intentionally expects a mounted RIFE implementation/model at
    FRAMEBOOST_RIFE_DIR. Keeping the runner isolated makes the API independent
    from a particular RIFE distribution and avoids shipping a fake CPU fallback.
    """
    rife_dir = Path(os.environ.get("FRAMEBOOST_RIFE_DIR", "/opt/rife"))
    script = rife_dir / "inference_video.py"
    if not script.exists():
        raise RuntimeError("RIFE worker is not installed at FRAMEBOOST_RIFE_DIR")

    # Common CLI contract used by the mounted worker. Adapt only these arguments
    # when deploying a different RIFE distribution.
    cmd = [
        "python3", str(script),
        "--video", str(input_path),
        "--output", str(output_path),
        "--fps", str(target_fps),
    ]
    subprocess.run(cmd, check=True, cwd=rife_dir)


def mux_audio(source: Path, silent_video: Path, final_output: Path) -> None:
    subprocess.run([
        "ffmpeg", "-y", "-i", str(silent_video), "-i", str(source),
        "-map", "0:v:0", "-map", "1:a?", "-c:v", "copy", "-c:a", "aac",
        "-shortest", str(final_output),
    ], check=True)
