import json
import urllib.error
from pathlib import Path

import pytest

from composition_learner import fetch
from composition_learner.cluster import build_templates, describe, merge_with_existing, render_summary
from composition_learner.coco import samples_from_coco
from composition_learner.features import pick_dominant
from composition_learner.portrait import KEYPOINTS, Kp, PortraitFeatures, compute_features, is_good_composition

FIXTURES = json.loads((Path(__file__).resolve().parents[2] / "shared" / "portrait_fixtures.json").read_text())


def to_kps(raw):
    return {n: Kp(x, y, bool(v)) for n, (x, y, v) in raw.items()}


@pytest.mark.parametrize("case", FIXTURES["cases"], ids=lambda c: c["name"])
def test_shared_fixtures(case):
    f = compute_features(to_kps(case["keypoints"]))
    exp = case["expected"]
    if exp is None:
        assert f is None
        return
    got = f.to_dict()
    for k, v in exp.items():
        if isinstance(v, float):
            assert got[k] == pytest.approx(v, abs=1e-5), k
        else:
            assert got[k] == v, k


def test_good_composition_filter():
    by_name = {c["name"]: compute_features(to_kps(c["keypoints"])) for c in FIXTURES["cases"]}
    assert is_good_composition(by_name["full_body_facing_right"])
    assert not is_good_composition(by_name["cut_at_knee"])  # 무릎에서 잘림
    assert is_good_composition(by_name["face_closeup_facing_left"])  # 클로즈업은 이마 잘림 허용
    head_cut = PortraitFeatures("waist", 0.5, 0.03, 0.17, 0.03 - 0.17 * 0.55, 0, None)
    assert not is_good_composition(head_cut)


def feat(shot, x, eye, size, face_dir=1):
    return PortraitFeatures(shot, x, eye, size, eye - size * 0.55, face_dir, None)


def test_build_templates_per_shot_with_mirroring_and_weights():
    items = [(feat("waist", 0.35, 0.33, 0.15), 1.0, "coco") for _ in range(6)]
    # 왼쪽을 보는 사진은 좌우 반전되어 같은 템플릿으로 모인다
    items += [(feat("waist", 0.65, 0.33, 0.15, face_dir=-1), 3.0, "images") for _ in range(6)]
    items += [(feat("waist", 0.5, 0.45, 0.30, face_dir=0), 1.0, "coco") for _ in range(6)]
    items += [(feat("full_body", 0.4, 0.2, 0.06), 1.0, "coco") for _ in range(3)]
    out = build_templates(items, max_k=2, min_per_cluster=5)
    assert out["schema_version"] == 2
    shots = {s["id"]: s for s in out["shots"]}
    assert list(shots) == ["full_body", "waist"]  # SHOT_TYPES 순서
    waist = shots["waist"]
    assert waist["samples"] == 18 and waist["sources"] == {"coco": 12, "images": 6}
    t = waist["templates"][0]  # 가중치가 큰 것 먼저
    assert t["subject_cx"] == pytest.approx(0.35) and t["support"] == 12 and t["weight"] == 24.0
    assert t["turned_ratio"] == 1.0
    assert "1/3 선" in t["description"] and "위 1/3" in t["description"]
    assert waist["templates"][1]["subject_cx"] == pytest.approx(0.5)
    assert t["tol_x"] >= 0.05 and t["tol_size"] >= 0.15 * 0.12


def test_describe_center_and_back_space():
    assert "가운데" in describe("chest", 0.5, 0.4)
    assert "뒤 여백" in describe("chest", 0.62, 0.4)
    assert "얼굴을 한쪽에 (시선 앞 여백)" in describe("knee", 0.42, 0.25)


def test_merge_keeps_old_shots_and_ignores_old_schema():
    learned = build_templates([(feat("waist", 0.35, 0.33, 0.15), 1.0, "coco")] * 25 + [(feat("face", 0.4, 0.4, 0.5), 1.0, "coco")] * 3)
    old = {"schema_version": 2, "shots": [{"id": "face", "label": "얼굴 클로즈업", "samples": 0, "templates": [{"id": "face-default"}]}]}
    merged, used = merge_with_existing(learned, old, min_samples=20)
    assert used == ["waist"]
    assert [s["id"] for s in merged["shots"]] == ["waist", "face"]
    assert merged["shots"][1]["templates"][0]["id"] == "face-default"
    # 예전(v1 장면) 형식은 버린다
    merged2, _ = merge_with_existing(learned, {"schema_version": 1, "scenes": []}, min_samples=20)
    assert [s["id"] for s in merged2["shots"]] == ["waist"]
    md = render_summary(merged, used, {"coco: 학습 사용": 25}, {"cc0": 2})
    assert "| 반신 | 25 | coco 25 | 1 | 학습 |" in md and "기본 규칙" in md and "coco: 학습 사용: 25" in md


def kp_list(points):
    """COCO keypoints 배열 (픽셀 좌표)."""
    out = []
    for n in KEYPOINTS:
        x, y, v = points.get(n, (0, 0, 0))
        out += [x, y, v]
    return out


def test_coco_samples_filters_landscape_crowds_and_non_dominant():
    big = {"nose": (300, 200, 2), "left_eye": (310, 190, 2), "right_eye": (290, 190, 2),
           "left_shoulder": (340, 300, 2), "right_shoulder": (260, 300, 2), "left_hip": (330, 500, 2),
           "right_hip": (270, 500, 2), "left_knee": (330, 650, 2), "right_knee": (270, 650, 1)}  # fmt: skip
    small = {k: (x / 4 + 500, y / 4, v) for k, (x, y, v) in big.items()}
    data = {
        "images": [
            {"id": 1, "width": 600, "height": 800},  # 세로, 주인공 1명 → 사용
            {"id": 2, "width": 800, "height": 600},  # 가로 → 제외
            {"id": 3, "width": 600, "height": 800},  # 비슷한 크기 2명 → 제외
            {"id": 4, "width": 600, "height": 800},  # 군중 → 제외
            {"id": 5, "width": 600, "height": 800},  # 큰 사람 + 작은 사람 → 사용
        ],
        "annotations": [
            {"image_id": 1, "keypoints": kp_list(big), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 2, "keypoints": kp_list(big), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 3, "keypoints": kp_list(big), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 3, "keypoints": kp_list({k: (x - 100, y, v) for k, (x, y, v) in big.items()}), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 4, "keypoints": kp_list(big), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 4, "keypoints": [0] * 51, "num_keypoints": 0, "iscrowd": 1},
            {"image_id": 5, "keypoints": kp_list(big), "num_keypoints": 9, "iscrowd": 0},
            {"image_id": 5, "keypoints": kp_list(small), "num_keypoints": 9, "iscrowd": 0},
        ],
    }
    samples = list(samples_from_coco(data))
    assert [s.ref for s in samples] == ["1", "5"]
    f = compute_features(samples[0].keypoints)
    assert f.shot == "knee" and f.eye_y == pytest.approx(190 / 800) and f.head_x == pytest.approx(0.5)
    assert len(list(samples_from_coco(data, include_landscape=True))) == 3


def test_pick_dominant_requires_clear_main_subject():
    a = {"a": Kp(0.1, 0.1, True), "b": Kp(0.5, 0.9, True)}
    b = {"a": Kp(0.6, 0.1, True), "b": Kp(0.9, 0.8, True)}
    assert pick_dominant([a, b]) is None
    assert pick_dominant([a]) is a


def test_parse_openverse_and_commons():
    ov = {"results": [
        {"id": "a", "url": "https://x/a.jpg", "width": 800, "height": 1200, "license": "cc0", "thumbnail": "https://t/a"},
        {"id": "b", "url": "https://x/b.jpg", "width": 1200, "height": 800},
        {"id": "c", "url": "https://x/c.jpg", "width": 300, "height": 500},
    ]}  # fmt: skip
    photos = fetch.parse_results(ov, "half_body")
    assert [p.id for p in photos] == ["ov-a"] and photos[0].group == "half_body" and photos[0].thumbnail == "https://t/a"
    wc = {"continue": {}, "query": {"pages": {
        "1": {"pageid": 1, "title": "File:A.jpg", "imageinfo": [{"width": 2000, "height": 3000, "thumburl": "https://u/a_1024.jpg",
              "descriptionurl": "https://c/A", "extmetadata": {"LicenseShortName": {"value": "CC BY-SA 4.0"}, "Artist": {"value": "Kim"}}}]},
        "2": {"pageid": 2, "title": "File:B.jpg", "imageinfo": [{"width": 3000, "height": 2000, "thumburl": "https://u/b.jpg"}]},
    }}}  # fmt: skip
    cp = fetch.parse_commons(wc, "full_body")
    assert [p.id for p in cp] == ["wc-1"] and cp[0].license == "CC BY-SA 4.0" and cp[0].url.endswith("_1024.jpg")
    assert "gsroffset=50" in fetch.build_commons_url("street portrait", 50)
    assert "aspect_ratio=tall" in fetch.build_query_url("woman", 2)
    assert [p.id for p in fetch.interleave(photos, cp)] == ["ov-a", "wc-1"]


def test_get_with_retry_backs_off_then_succeeds(monkeypatch):
    calls = []

    def fake_get(url, timeout=30, auth=False):
        calls.append(url)
        if len(calls) < 3:
            raise urllib.error.HTTPError(url, 500, "err", {}, None)
        return b"ok"

    waits = []
    monkeypatch.setattr(fetch, "_get", fake_get)
    assert fetch.get_with_retry("u", backoff=1, sleep=waits.append) == b"ok"
    assert waits == [1, 3]


def test_get_with_retry_gives_up_with_rate_limited(monkeypatch):
    def fake_get(url, timeout=30, auth=False):
        raise urllib.error.HTTPError(url, 429, "slow down", {"Retry-After": "2"}, None)

    waits = []
    monkeypatch.setattr(fetch, "_get", fake_get)
    with pytest.raises(fetch.RateLimited):
        fetch.get_with_retry("u", retries=2, sleep=waits.append)
    assert waits == [2.0, 2.0]


def test_download_skips_existing_and_falls_back_to_thumbnail(monkeypatch, tmp_path):
    def fake_get(url, timeout=30, auth=False):
        if "orig" in url:
            raise OSError("403")
        return b"x" * 20_000

    monkeypatch.setattr(fetch, "_get", fake_get)
    mk = lambda i: fetch.Photo(i, "g", f"https://orig/{i}.jpg", "", "", "cc0", "", "", "", "", 800, 1200, f"https://thumb/{i}")
    assert fetch.download([mk("a"), mk("b")], tmp_path, limit=5, delay=0) == 2
    assert fetch.download([mk("a"), mk("c")], tmp_path, limit=5, delay=0) == 3  # a 는 이미 있음
    assert fetch.count_existing(tmp_path) == 3 and (tmp_path / "c.jpg").exists()


def test_frontal_faces_fold_to_left_half_and_cluster_by_position():
    from composition_learner.cluster import position_table

    assert feat("waist", 0.7, 0.3, 0.15, face_dir=0).canonical_x == pytest.approx(0.3)
    assert feat("waist", 0.7, 0.3, 0.15, face_dir=1).canonical_x == pytest.approx(0.7)  # 뒤 여백 구도는 유지
    # 왼쪽 1/3 과 오른쪽 1/3 정면 사진이 '가운데'로 평균 나지 않고 같은 1/3 템플릿으로 모인다
    items = [(feat("waist", 0.33, 0.3, 0.15, face_dir=0), 1.0, "images") for _ in range(6)]
    items += [(feat("waist", 0.67, 0.3, 0.15, face_dir=0), 1.0, "images") for _ in range(6)]
    items += [(feat("waist", 0.5, 0.3, 0.15, face_dir=0), 1.0, "coco") for _ in range(6)]
    out = build_templates(items, max_k=2, min_per_cluster=5)
    xs = sorted(t["subject_cx"] for t in out["shots"][0]["templates"])
    assert xs == [pytest.approx(0.33, abs=0.01), pytest.approx(0.5, abs=0.01)]
    table = position_table(items)
    assert "| images | 반신 | 12 | 50% | 0% | 50% | 0% |" in table
    assert "| coco | 반신 | 6 | 0% | 100% | 0% | 0% |" in table
