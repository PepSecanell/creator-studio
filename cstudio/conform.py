"""Make any camera file safe to edit: constant 30 fps, SDR colour, upright, optionally un-mirrored."""
from __future__ import annotations

from pathlib import Path

from .util import ffmpeg, probe, run

FPS = 30
_tonemap_cache: str | None = None


def _hdr_filter() -> str:
    """Pick an HDR to SDR filter chain this ffmpeg build can run."""
    global _tonemap_cache
    if _tonemap_cache is None:
        filters = run(["ffmpeg", "-hide_banner", "-filters"], what="ffmpeg").stdout
        if " zscale " in filters:
            _tonemap_cache = ("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,"
                              "zscale=t=bt709:m=bt709:r=tv,format=yuv420p")
        else:
            _tonemap_cache = "colorspace=all=bt709:iall=bt2020:fast=1,format=yuv420p"
    return _tonemap_cache


def needs_conform(info: dict) -> bool:
    return bool(info.get("hdr") or info.get("rotation") or abs(info.get("fps", 0) - FPS) > 0.05
                or info.get("pix_fmt") not in ("yuv420p", None))


def conform(src: Path, dst: Path, *, unmirror: bool = False, force: bool = False, audio: Path | None = None) -> Path:
    """Write dst (mp4, 30 fps, SDR, AAC 48k stereo). Returns dst. `audio` replaces the sound (a separate mic file).
    Skips work if dst is newer than its inputs."""
    src, dst = Path(src), Path(dst)
    newest = max(src.stat().st_mtime, Path(audio).stat().st_mtime if audio else 0)
    if dst.exists() and not force and dst.stat().st_mtime >= newest:
        return dst
    info = probe(src)
    vf = []
    if info.get("hdr"):
        vf.append(_hdr_filter())
    if unmirror:
        vf.append("hflip")
    vf += [f"fps={FPS}", "format=yuv420p"]
    dst.parent.mkdir(parents=True, exist_ok=True)
    args = ["-i", src] + (["-i", audio, "-map", "0:v", "-map", "1:a"] if audio else []) + ["-vf", ",".join(vf), "-c:v", "libx264", "-preset", "veryfast", "-crf", "14",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709"]
    if info["has_audio"] or audio:
        args += ["-c:a", "aac", "-b:a", "192k", "-ar", "48000", "-ac", "2"]
    else:
        args += ["-an"]
    ffmpeg([*args, "-movflags", "+faststart", dst], what="conform")
    return dst
