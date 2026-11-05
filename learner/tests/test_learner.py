import math

import numpy as np

from composition_learner.cluster import build_templates
from composition_learner.features import CompositionFeatures, bbox_from_landmarks, detect_horizon


def feat(scene, cx, cy, h, horizon=None):
    return CompositionFeatures("x.jpg", scene, "portrait", cx, cy, h, cy - h / 2, horizon, 0.0 if horizon else None)


def test_bbox_from_landmarks_ignores_low_visibility_and_pads_head():
    pts = [(0.4, 0.3, 0.9), (0.6, 0.3, 0.9), (0.45, 0.8, 0.9), (0.55, 0.8, 0.9), (0.0, 0.0, 0.1)]
    box = bbox_from_landmarks(pts)
    assert box is not None
    assert math.isclose(box.left, 0.4) and math.isclose(box.right, 0.6)
    assert box.top < 0.3  # 머리 위로 늘어남
    assert math.isclose(box.bottom, 0.8)


def test_bbox_requires_enough_points():
    assert bbox_from_landmarks([(0.5, 0.5, 0.9)] * 3) is None


def test_detect_horizon_finds_tilted_line():
    img = np.zeros((480, 640), dtype=np.uint8)
    img[:] = 40
    # 위쪽 하늘(밝음) / 아래쪽 바다(어두움), 약간 기울어진 경계
    for x in range(640):
        y = int(160 + x * math.tan(math.radians(3)))
        img[:y, x] = 220
    res = detect_horizon(img)
    assert res is not None
    y, tilt = res
    assert 0.3 < y < 0.45
    assert 1.5 < tilt < 4.5


def test_build_templates_clusters_two_compositions():
    feats = [feat("beach", 0.33 + d, 0.70, 0.15) for d in (-0.01, 0, 0.01, 0.02)]
    feats += [feat("beach", 0.66 + d, 0.60, 0.60, horizon=0.35) for d in (-0.01, 0, 0.01)]
    feats += [CompositionFeatures("n.jpg", "beach", "portrait", None, None, None, None, 0.4, 0.0)]
    out = build_templates(feats, max_k=2, min_per_cluster=3)
    assert out["schema_version"] == 1
    scene = out["scenes"][0]
    assert scene["id"] == "beach" and scene["label"] == "바다" and scene["samples"] == 7
    t = sorted(scene["templates"], key=lambda t: t["subject_cx"])
    assert len(t) == 2
    assert abs(t[0]["subject_cx"] - 0.335) < 0.02 and t[0]["support"] == 4
    assert "왼쪽 1/3" in t[0]["description"] and "작게" in t[0]["description"]
    assert t[1]["horizon_y"] == 0.35 and "크게" in t[1]["description"]
    assert t[0]["tol_x"] >= 0.05  # 최소 허용 오차


def test_build_templates_single_cluster_when_few_samples():
    out = build_templates([feat("city", 0.5, 0.5, 0.4), feat("city", 0.52, 0.5, 0.42)])
    assert len(out["scenes"][0]["templates"]) == 1
