"""Pick a crop window for each cut so the face sits where a vertical video wants it.

Face finding uses OpenCV's Haar cascade when opencv is installed. Without it, or when no face is found,
the crop is centred. Works on any OS.
"""
from __future__ import annotations

import statistics
from pathlib import Path

EYE_LINE = 0.40      # eyes sit this far down the frame


def face_track(src: Path, step: float = 0.5) -> list[tuple[float, float, float, float]]:
    """Return [(t, cx, cy, face_h)] in source pixels. Empty when opencv or a face is missing."""
    try:
        import cv2
    except ImportError:
        return []
    if not hasattr(cv2, "CascadeClassifier"):
        return []
    cap = cv2.VideoCapture(str(src))
    if not cap.isOpened():
        return []
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    cascade = cv2.CascadeClassifier(cv2.data.haarcascades + "haarcascade_frontalface_default.xml")
    out = []
    n = 0
    while n < total:
        cap.set(cv2.CAP_PROP_POS_FRAMES, n)
        ok, frame = cap.read()
        if not ok:
            break
        scale = 480 / frame.shape[1] if frame.shape[1] > 480 else 1.0
        small = cv2.resize(frame, None, fx=scale, fy=scale) if scale != 1.0 else frame
        gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
        faces = cascade.detectMultiScale(gray, 1.15, 5, minSize=(40, 40))
        if len(faces):
            x, y, w, h = max(faces, key=lambda f: f[2] * f[3])
            out.append((n / fps, (x + w / 2) / scale, (y + h / 2) / scale, h / scale))
        n += max(1, int(step * fps))
    cap.release()
    return out


def window(track, t0: float, t1: float, src_w: int, src_h: int, aspect: float, zoom: float = 1.0):
    """Crop (x, y, w, h) in source pixels with width/height == aspect, face-aware, inside the frame."""
    if src_w / src_h > aspect:
        ch, cw = float(src_h), src_h * aspect
    else:
        cw, ch = float(src_w), src_w / aspect
    cw, ch = cw / zoom, ch / zoom
    pts = [p for p in track if t0 - 0.25 <= p[0] <= t1 + 0.25] or []
    if pts:
        cx = statistics.median(p[1] for p in pts)
        cy = statistics.median(p[2] for p in pts)
        x = cx - cw / 2
        y = cy - EYE_LINE * ch
    else:
        x = (src_w - cw) / 2
        y = (src_h - ch) / 2
    x = min(max(0.0, x), src_w - cw)
    y = min(max(0.0, y), src_h - ch)
    return int(x) // 2 * 2, int(y) // 2 * 2, int(cw) // 2 * 2, int(ch) // 2 * 2
