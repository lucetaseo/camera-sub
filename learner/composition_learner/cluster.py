"""인물 구도 특징을 샷 종류별로 군집화(KMeans)해서 구도 템플릿을 만든다."""
from __future__ import annotations

from collections import Counter, defaultdict
from typing import Iterable, Optional

import numpy as np

from .portrait import SHOT_LABELS, SHOT_TYPES, PortraitFeatures

SCHEMA_VERSION = 2

# 데이터가 적어도 앱이 지나치게 깐깐하지 않도록 쓰는 최소 허용 오차
MIN_TOL_X = 0.05
MIN_TOL_EYE = 0.04
MIN_TOL_SIZE_RATIO = 0.12  # head_size 의 12%


def describe(shot: str, x: float, eye_y: float) -> str:
    """오른쪽을 보는 기준(canonical) 템플릿을 사람이 읽는 설명으로."""
    if abs(x - 0.5) < 0.06:
        horiz = "얼굴을 가운데"
    elif x < 0.5:
        third = "1/3 선" if abs(x - 1 / 3) < 0.07 else "쪽"
        horiz = f"얼굴을 시선 반대편 {third}에 (시선 앞 여백)"
    else:
        horiz = "얼굴을 시선 쪽에 (뒤 여백)"
    if abs(eye_y - 1 / 3) < 0.05:
        eye = "눈높이는 위 1/3 선"
    elif eye_y < 1 / 3:
        eye = "눈높이는 위쪽"
    else:
        eye = "눈높이는 화면 중간쯤"
    return f"{SHOT_LABELS.get(shot, shot)} · {horiz} · {eye}"


def _wstats(x: np.ndarray, w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    mean = np.average(x, axis=0, weights=w)
    std = np.sqrt(np.average((x - mean) ** 2, axis=0, weights=w))
    return mean, std


def build_templates(
    items: Iterable[tuple[PortraitFeatures, float, str]],
    max_k: int = 3,
    min_per_cluster: int = 5,
    seed: int = 0,
) -> dict:
    """items: (특징, 가중치, 출처)."""
    from sklearn.cluster import KMeans

    by_shot: dict[str, list[tuple[PortraitFeatures, float, str]]] = defaultdict(list)
    for f, w, src in items:
        by_shot[f.shot].append((f, w, src))

    shots = []
    for shot in SHOT_TYPES:
        group = by_shot.get(shot)
        if not group:
            continue
        x = np.array([[f.canonical_x, f.eye_y, f.head_size] for f, _, _ in group], dtype=float)
        w = np.array([wt for _, wt, _ in group], dtype=float)
        # 크기(head_size)는 샷마다 범위가 달라서 위치와 비슷한 비중이 되도록 정규화
        scale = np.array([1.0, 1.0, max(1e-6, float(np.median(x[:, 2])))])
        k = max(1, min(max_k, len(group) // min_per_cluster))
        labels = (
            np.zeros(len(group), dtype=int)
            if k == 1
            else KMeans(n_clusters=k, n_init=10, random_state=seed).fit_predict(x / scale, sample_weight=w)
        )
        templates = []
        for c in range(k):
            idx = np.where(labels == c)[0]
            if len(idx) == 0:
                continue
            mean, std = _wstats(x[idx], w[idx])
            facing = Counter(group[i][0].face_dir != 0 for i in idx)
            templates.append(
                {
                    "id": f"{shot}-{c + 1}",
                    "description": describe(shot, mean[0], mean[1]),
                    "subject_cx": round(float(mean[0]), 4),
                    "eye_y": round(float(mean[1]), 4),
                    "head_size": round(float(mean[2]), 4),
                    "tol_x": round(max(MIN_TOL_X, float(std[0])), 4),
                    "tol_eye": round(max(MIN_TOL_EYE, float(std[1])), 4),
                    "tol_size": round(max(mean[2] * MIN_TOL_SIZE_RATIO, float(std[2])), 4),
                    "turned_ratio": round(facing[True] / len(idx), 3),
                    "support": int(len(idx)),
                    "weight": round(float(w[idx].sum()), 1),
                }
            )
        templates.sort(key=lambda t: -t["weight"])
        shots.append(
            {
                "id": shot,
                "label": SHOT_LABELS[shot],
                "samples": len(group),
                "sources": dict(Counter(src for _, _, src in group)),
                "templates": templates,
            }
        )
    return {"schema_version": SCHEMA_VERSION, "shots": shots}


def merge_with_existing(learned: dict, existing: Optional[dict], min_samples: int = 20) -> tuple[dict, list[str]]:
    """표본이 충분한 샷만 학습 결과로 바꾸고, 나머지는 기존 템플릿을 유지한다."""
    good = {s["id"]: s for s in learned["shots"] if s["samples"] >= min_samples}
    old = (existing or {}).get("shots", []) if (existing or {}).get("schema_version") == SCHEMA_VERSION else []
    merged = {s["id"]: s for s in old}
    merged.update(good)
    ordered = [merged[s] for s in SHOT_TYPES if s in merged]
    return {"schema_version": SCHEMA_VERSION, "shots": ordered}, sorted(good, key=SHOT_TYPES.index)


def render_summary(
    result: dict, learned_ids: list[str], stats: dict[str, int], licenses: dict[str, int]
) -> str:
    lines = ["# 인물 구도 학습 결과", ""]
    if stats:
        lines += ["## 데이터", ""]
        lines += [f"- {k}: {v:,}" for k, v in stats.items()]
        lines.append("")
    lines += ["| 샷 | 학습 표본 | 출처별 | 템플릿 | 상태 |", "|---|---|---|---|---|"]
    for s in result["shots"]:
        learned = s["id"] in learned_ids
        src = ", ".join(f"{k} {v:,}" for k, v in s.get("sources", {}).items()) or "-"
        state = "학습" if learned else ("이전 학습 유지" if s.get("samples") else "기본 규칙")
        lines.append(f"| {s['label']} | {s.get('samples', 0):,} | {src} | {len(s['templates'])} | {state} |")
    lines += ["", "## 템플릿 (오른쪽을 보는 인물 기준, 왼쪽을 보면 좌우 반전)", ""]
    for s in result["shots"]:
        for t in s["templates"]:
            if "eye_y" not in t:
                continue
            lines.append(
                f"- `{t['id']}` {t['description']} — 얼굴 x={t['subject_cx']:.2f}, 눈높이 y={t['eye_y']:.2f}, "
                f"얼굴크기={t['head_size']:.3f}, 표본 {t.get('support', 0):,}"
            )
    if licenses:
        lines += ["", "## 내려받은 사진 라이선스", ""]
        lines += [f"- {k}: {v:,}장" for k, v in sorted(licenses.items())]
    lines += ["", "사진 자체는 저장소에 올리지 않고, 관절 위치에서 계산한 통계만 템플릿에 남깁니다."]
    return "\n".join(lines) + "\n"
