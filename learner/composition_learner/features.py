"""사진에서 주인공 인물의 관절 위치를 뽑는다 (MediaPipe PoseLandmarker)."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Optional, Sequence

from .portrait import KEYPOINTS, MEDIAPIPE_INDEX, Kp


@dataclass
class Sample:
    """학습 데이터 한 건 (사진 한 장의 주인공 한 명)."""

    source: str  # "images" | "coco"
    ref: str  # 파일 이름이나 COCO image id
    orientation: str  # "portrait" | "landscape"
    keypoints: Mapping[str, Kp]


def _extent(kps: Mapping[str, Kp]) -> float:
    pts = [p for p in kps.values() if p.visible and 0 <= p.x <= 1 and 0 <= p.y <= 1]
    if len(pts) < 2:
        return 0.0
    xs, ys = [p.x for p in pts], [p.y for p in pts]
    return (max(xs) - min(xs)) * (max(ys) - min(ys))


def pick_dominant(people: Sequence[Mapping[str, Kp]], min_ratio: float = 2.0) -> Optional[Mapping[str, Kp]]:
    """한 사람이 확실한 주인공인 사진만 쓴다 (두 번째로 큰 사람보다 min_ratio 배 이상 커야 함)."""
    if not people:
        return None
    ranked = sorted(people, key=_extent, reverse=True)
    if _extent(ranked[0]) <= 0:
        return None
    if len(ranked) > 1 and _extent(ranked[0]) < min_ratio * _extent(ranked[1]):
        return None
    return ranked[0]


def mediapipe_to_keypoints(landmarks, min_visibility: float = 0.5) -> dict[str, Kp]:
    return {
        name: Kp(landmarks[i].x, landmarks[i].y, (landmarks[i].visibility or 0.0) >= min_visibility)
        for name, i in MEDIAPIPE_INDEX.items()
    }


class FeatureExtractor:
    def __init__(self, model_path: Path):
        from mediapipe.tasks.python import BaseOptions, vision

        options = vision.PoseLandmarkerOptions(
            base_options=BaseOptions(model_asset_path=str(model_path)),
            running_mode=vision.RunningMode.IMAGE,
            num_poses=4,
        )
        self._landmarker = vision.PoseLandmarker.create_from_options(options)

    def close(self) -> None:
        self._landmarker.close()

    def extract(self, image_path: Path) -> Optional[Sample]:
        import cv2
        import mediapipe as mp

        bgr = cv2.imread(str(image_path))
        if bgr is None:
            return None
        h, w = bgr.shape[:2]
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        result = self._landmarker.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
        people = [mediapipe_to_keypoints(pose) for pose in result.pose_landmarks or []]
        main = pick_dominant(people)
        if main is None:
            return None
        return Sample("images", image_path.name, "portrait" if h >= w else "landscape", main)


assert set(MEDIAPIPE_INDEX) == set(KEYPOINTS)
