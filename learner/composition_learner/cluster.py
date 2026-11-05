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


def merge_with_existing(learned: dict, existing: dict | None, min_samples: int = 8) -> tuple[dict, list[str]]:
    """학습 결과가 충분한 장면만 교체하고, 나머지는 기존(기본 규칙) 템플릿을 유지한다.

    반환: (합쳐진 결과, 학습 결과로 교체된 장면 id 목록)
    """
    good = {s["id"]: s for s in learned["scenes"] if s["samples"] >= min_samples}
    scenes = []
    seen = set()
    for s in (existing or {}).get("scenes", []):
        scenes.append(good.get(s["id"], s))
        seen.add(s["id"])
    for sid, s in good.items():
        if sid not in seen:
            scenes.append(s)
    return {"schema_version": SCHEMA_VERSION, "scenes": scenes}, sorted(good)


def render_summary(result: dict, learned_ids: list[str], image_counts: dict[str, int], licenses: dict[str, int]) -> str:
    lines = ["# 구도 학습 결과", ""]
    lines.append("| 장면 | 사진 | 인물 검출 | 템플릿 | 출처 |")
    lines.append("|---|---|---|---|---|")
    for s in result["scenes"]:
        learned = s["id"] in learned_ids
        lines.append(
            f"| {s['label']} | {image_counts.get(s['id'], 0)} | {s['samples'] if learned else '-'} | "
            f"{len(s['templates'])} | {'학습' if learned else '기본 규칙'} |"
        )
    lines += ["", "## 학습된 템플릿", ""]
    for s in result["scenes"]:
        if s["id"] not in learned_ids:
            continue
        for t in s["templates"]:
            lines.append(
                f"- **{s['label']}** `{t['id']}`: {t['description']} "
                f"(x={t['subject_cx']:.2f}, y={t['subject_cy']:.2f}, 키={t['subject_h']:.2f}, 사진 {t['support']}장)"
            )
    if licenses:
        lines += ["", "## 사진 라이선스", ""]
        lines += [f"- {k}: {v}장" for k, v in sorted(licenses.items())]
        lines += ["", "사진 자체는 저장소에 올리지 않고, 위치·크기 같은 통계만 템플릿에 남깁니다."]
    return "\n".join(lines) + "\n"
