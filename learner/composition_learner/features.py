"""사진 한 장에서 구도 특징(Composition features)을 뽑아내는 모듈.

모든 좌표는 0~1로 정규화된다. (0,0)=왼쪽 위, (1,1)=오른쪽 아래.
앱(Flutter)의 GuideEngine 이 같은 정의를 사용하므로 둘을 바꿀 때는 함께 바꿔야 한다.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional, Sequence

import numpy as np


@dataclass
class BBox:
    left: float
    top: float
    right: float
    bottom: float

    @property
    def cx(self) -> float:
        return (self.left + self.right) / 2

    @property
    def cy(self) -> float:
        return (self.top + self.bottom) / 2

    @property
    def height(self) -> float:
        return self.bottom - self.top


@dataclass
class CompositionFeatures:
    """학습에 쓰는 한 장의 구도 정보."""

    image: str
    scene: str
    orientation: str  # "portrait" | "landscape"
    subject_cx: Optional[float]  # 인물 중심 x
    subject_cy: Optional[float]  # 인물 중심 y
    subject_h: Optional[float]  # 인물 키 / 화면 높이
    head_y: Optional[float]  # 인물 머리 위 y (머리 위 여백)
    horizon_y: Optional[float]  # 수평선 y
    horizon_tilt_deg: Optional[float]  # 수평선 기울기(도)

    def to_dict(self) -> dict:
        return asdict(self)

    @property
    def has_subject(self) -> bool:
        return self.subject_cx is not None


def bbox_from_landmarks(
    points: Sequence[tuple[float, float, float]],
    min_visibility: float = 0.3,
    head_padding: float = 0.08,
) -> Optional[BBox]:
    """포즈 랜드마크(x, y, visibility, 정규화 좌표)로 인물 박스를 만든다.

    랜드마크는 머리 꼭대기가 아니라 눈/코에서 끝나므로 키의 일부만큼 위로 늘린다.
    """
    pts = [(x, y) for x, y, v in points if v >= min_visibility]
    if len(pts) < 4:
        return None
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    top, bottom = min(ys), max(ys)
    h = bottom - top
    top -= h * head_padding
    clamp = lambda v: max(0.0, min(1.0, v))
    return BBox(clamp(min(xs)), clamp(top), clamp(max(xs)), clamp(bottom))


def detect_horizon(gray: np.ndarray, max_tilt_deg: float = 15.0) -> Optional[tuple[float, float]]:
    """가장 길고 거의 수평인 선을 찾아 (y 정규화, 기울기 도)를 돌려준다."""
    import cv2

    h, w = gray.shape[:2]
    scale = 640 / max(h, w)
    if scale < 1:
        gray = cv2.resize(gray, (int(w * scale), int(h * scale)))
        h, w = gray.shape[:2]
    blur = cv2.GaussianBlur(gray, (5, 5), 0)
    edges = cv2.Canny(blur, 50, 150)
    lines = cv2.HoughLinesP(
        edges, 1, np.pi / 180, threshold=80, minLineLength=int(w * 0.35), maxLineGap=int(w * 0.03)
    )
    if lines is None:
        return None
    best = None
    best_len = 0.0
    for x1, y1, x2, y2 in lines.reshape(-1, 4):
        dx, dy = x2 - x1, y2 - y1
        if dx == 0:
            continue
        angle = math.degrees(math.atan2(dy, dx))
        if abs(angle) > max_tilt_deg:
            continue
        length = math.hypot(dx, dy)
        if length > best_len:
            best_len = length
            best = ((y1 + y2) / 2 / h, angle)
    return best


class FeatureExtractor:
    """MediaPipe PoseLandmarker + OpenCV 로 사진에서 특징을 뽑는다."""

    def __init__(self, model_path: Path):
        from mediapipe.tasks.python import BaseOptions, vision

        options = vision.PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(model_path)),
            running_mode=vision.RunningMode.IMAGE,
            num_poses=3,
        )
        self._landmarker = vision.PoseLandmarker.create_from_options(options)

    def close(self) -> None:
        self._landmarker.close()

    def extract(self, image_path: Path, scene: str) -> Optional[CompositionFeatures]:
        import cv2
        import mediapipe as mp

        bgr = cv2.imread(str(image_path))
        if bgr is None:
            return None
        h, w = bgr.shape[:2]
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        result = self._landmarker.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))

        # 여러 명이면 가장 큰 사람을 주인공으로 본다.
        subject: Optional[BBox] = None
        for pose in result.pose_landmarks or []:
            box = bbox_from_landmarks([(p.x, p.y, p.visibility or 0.0) for p in pose])
            if box and (subject is None or box.height > subject.height):
                subject = box

        horizon = detect_horizon(cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY))
        return CompositionFeatures(
            image=image_path.name,
            scene=scene,
            orientation="portrait" if h >= w else "landscape",
            subject_cx=subject.cx if subject else None,
            subject_cy=subject.cy if subject else None,
            subject_h=subject.height if subject else None,
            head_y=subject.top if subject else None,
            horizon_y=horizon[0] if horizon else None,
            horizon_tilt_deg=horizon[1] if horizon else None,
        )
