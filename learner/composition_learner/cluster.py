"""여러 장의 구도 특징을 묶어서(KMeans) 장면별 구도 템플릿을 만든다."""
from __future__ import annotations

from collections import defaultdict
from typing import Iterable

import numpy as np

from .features import CompositionFeatures

SCHEMA_VERSION = 1

# 장면 폴더 이름 → 앱에 보일 한국어 이름
SCENE_LABELS = {
    "landscape": "풍경",
    "beach": "바다",
    "city": "도시/거리",
    "architecture": "건물/대칭",
    "portrait": "인물 클로즈업",
}

# 학습 데이터가 부족해도 앱이 동작하도록 쓰는 최소 허용 오차
MIN_TOL_POS = 0.05
MIN_TOL_SIZE = 0.04


def _describe(cx: float, cy: float, h: float) -> str:
    """템플릿을 사람이 읽을 수 있는 설명으로 바꾼다."""
    if abs(cx - 1 / 3) < 0.08:
        horiz = "왼쪽 1/3 선"
    elif abs(cx - 2 / 3) < 0.08:
        horiz = "오른쪽 1/3 선"
    elif abs(cx - 0.5) < 0.06:
        horiz = "정중앙"
    else:
        horiz = "왼쪽" if cx < 0.5 else "오른쪽"
    if h < 0.25:
        size = "작게(배경 강조)"
    elif h < 0.55:
        size = "중간 크기"
    else:
        size = "크게(인물 강조)"
    return f"인물을 {horiz}에 {size}"


def build_templates(
    features: Iterable[CompositionFeatures], max_k: int = 3, min_per_cluster: int = 3, seed: int = 0
) -> dict:
    from sklearn.cluster import KMeans

    by_scene: dict[str, list[CompositionFeatures]] = defaultdict(list)
    for f in features:
        if f.has_subject:
            by_scene[f.scene].append(f)

    scenes = []
    for scene, items in sorted(by_scene.items()):
        x = np.array([[f.subject_cx, f.subject_cy, f.subject_h] for f in items], dtype=float)
        k = max(1, min(max_k, len(items) // min_per_cluster))
        if k == 1:
            labels = np.zeros(len(items), dtype=int)
        else:
            labels = KMeans(n_clusters=k, n_init=10, random_state=seed).fit_predict(x)

        templates = []
        for c in range(k):
            idx = np.where(labels == c)[0]
            members = [items[i] for i in idx]
            pts = x[idx]
            mean = pts.mean(axis=0)
            std = pts.std(axis=0)
            horizons = [m.horizon_y for m in members if m.horizon_y is not None]
            heads = [m.head_y for m in members if m.head_y is not None]
            templates.append(
                {
                    "id": f"{scene}-{c + 1}",
                    "description": _describe(*mean),
                    "subject_cx": round(float(mean[0]), 4),
                    "subject_cy": round(float(mean[1]), 4),
                    "subject_h": round(float(mean[2]), 4),
                    "tol_x": round(max(MIN_TOL_POS, float(std[0])), 4),
                    "tol_y": round(max(MIN_TOL_POS, float(std[1])), 4),
                    "tol_h": round(max(MIN_TOL_SIZE, float(std[2])), 4),
                    "horizon_y": round(float(np.median(horizons)), 4) if horizons else None,
                    "head_y": round(float(np.median(heads)), 4) if heads else None,
                    "support": len(members),
                }
            )
        templates.sort(key=lambda t: -t["support"])
        scenes.append(
            {"id": scene, "label": SCENE_LABELS.get(scene, scene), "samples": len(items), "templates": templates}
        )

    return {"schema_version": SCHEMA_VERSION, "scenes": scenes}
