"""COCO 2017 사람 관절 데이터(person_keypoints_*.json)를 학습 데이터로 쓴다.

COCO 는 Flickr 사진 수만 장에 사람 관절 위치를 사람이 직접 표시한 공개 데이터셋이다.
(주석: CC BY 4.0, https://cocodataset.org/#termsofuse)
여기서는 사진을 내려받지 않고 주석의 숫자(관절 좌표)만 쓴다.
"""
from __future__ import annotations

import json
from collections import defaultdict
from pathlib import Path
from typing import Iterator

from .features import Sample, pick_dominant
from .portrait import KEYPOINTS, Kp

ANNOTATIONS_URL = "http://images.cocodataset.org/annotations/annotations_trainval2017.zip"


def samples_from_coco(data: dict, min_keypoints: int = 6, include_landscape: bool = False) -> Iterator[Sample]:
    images = {img["id"]: img for img in data["images"]}
    people: dict[int, list[dict]] = defaultdict(list)
    crowded: set[int] = set()
    for ann in data["annotations"]:
        if ann.get("iscrowd"):
            crowded.add(ann["image_id"])
        else:
            people[ann["image_id"]].append(ann)

    for image_id, anns in people.items():
        if image_id in crowded:
            continue
        img = images[image_id]
        w, h = img["width"], img["height"]
        portrait = h > w
        if not portrait and not include_landscape:
            continue
        persons = []
        for ann in anns:
            k = ann["keypoints"]
            kps = {name: Kp(k[i * 3] / w, k[i * 3 + 1] / h, k[i * 3 + 2] > 0) for i, name in enumerate(KEYPOINTS)}
            persons.append((ann.get("num_keypoints", 0), kps))
        main = pick_dominant([kps for _, kps in persons])
        if main is None:
            continue
        if sum(p.visible for p in main.values()) < min_keypoints:
            continue
        yield Sample("coco", str(image_id), "portrait" if portrait else "landscape", main)


def load_coco(paths: list[Path], **kwargs) -> Iterator[Sample]:
    for path in paths:
        with path.open(encoding="utf-8") as fp:
            data = json.load(fp)
        yield from samples_from_coco(data, **kwargs)
