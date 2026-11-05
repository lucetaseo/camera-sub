"""인물 구도 학습 명령줄 도구.

    python -m composition_learner.cli --images ../references --coco coco/person_keypoints_*.json \
        --out ../app/assets/templates.json --summary-out reports/training_summary.md

- --images: 하위 폴더 아래 사진들 (MediaPipe 로 관절 검출)
- --coco:   COCO person_keypoints JSON (사진 없이 관절 주석만 사용)
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from collections import Counter
from pathlib import Path

from .cluster import build_templates, merge_with_existing, position_table, render_summary
from .portrait import compute_features, is_good_composition

MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/pose_landmarker/"
    "pose_landmarker_lite/float16/latest/pose_landmarker_lite.task"
)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def ensure_model(path: Path) -> Path:
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        print(f"포즈 모델 다운로드 중: {MODEL_URL}", file=sys.stderr)
        urllib.request.urlretrieve(MODEL_URL, path)
    return path


def iter_image_samples(root: Path, model: Path):
    from .features import FeatureExtractor

    images = sorted(f for f in root.rglob("*") if f.suffix.lower() in IMAGE_EXTS)
    print(f"사진 {len(images):,}장 분석 중...", file=sys.stderr)
    extractor = FeatureExtractor(ensure_model(model))
    try:
        for i, img in enumerate(images, 1):
            s = extractor.extract(img)
            if s is not None:
                yield s
            if i % 200 == 0:
                print(f"  {i:,}/{len(images):,}", file=sys.stderr)
    finally:
        extractor.close()


def license_counts(references: Path) -> dict[str, int]:
    counts: Counter[str] = Counter()
    for credits in references.rglob("credits.jsonl"):
        for line in credits.read_text(encoding="utf-8").splitlines():
            if line.strip():
                counts[json.loads(line).get("license", "?")] += 1
    return dict(counts)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="인물 사진 구도 템플릿을 학습합니다.")
    p.add_argument("--images", type=Path, help="사진 폴더 (하위 폴더 포함)")
    p.add_argument("--coco", type=Path, nargs="*", default=[], help="COCO person_keypoints JSON")
    p.add_argument("--out", type=Path, default=Path("templates.json"))
    p.add_argument("--features-out", type=Path, help="학습에 쓴 특징을 JSONL 로 저장")
    p.add_argument("--summary-out", type=Path, help="학습 요약(Markdown)")
    p.add_argument("--model", type=Path, default=Path(__file__).resolve().parent.parent / "models" / "pose_landmarker_lite.task")
    p.add_argument("--image-weight", type=float, default=3.0, help="직접 고르거나 검색한 인물 사진의 가중치")
    p.add_argument("--coco-weight", type=float, default=0.25, help="COCO(일상 스냅) 가중치. 수가 많아 낮게 둔다")
    p.add_argument("--include-landscape", action="store_true", help="가로 사진도 학습 (앱은 세로 촬영 기준)")
    p.add_argument("--max-k", type=int, default=3)
    p.add_argument("--min-samples", type=int, default=20, help="이보다 표본이 적은 샷은 기존 템플릿 유지")
    args = p.parse_args(argv)

    if not args.images and not args.coco:
        p.error("--images 나 --coco 중 하나는 필요합니다")

    sources = []
    if args.images and args.images.exists():
        sources.append(iter_image_samples(args.images, args.model))
    if args.coco:
        from .coco import load_coco

        sources.append(load_coco(args.coco, include_landscape=args.include_landscape))

    stats: Counter[str] = Counter()
    items = []
    feats_fp = args.features_out.open("w", encoding="utf-8") if args.features_out else None
    try:
        for source in sources:
            for s in source:
                stats[f"{s.source}: 주인공 인물 검출"] += 1
                if s.orientation != "portrait" and not args.include_landscape:
                    stats[f"{s.source}: 가로 사진 제외"] += 1
                    continue
                f = compute_features(s.keypoints)
                if f is None:
                    stats[f"{s.source}: 얼굴 안 보임 제외"] += 1
                    continue
                if not is_good_composition(f):
                    stats[f"{s.source}: 관절/머리 잘림 제외"] += 1
                    continue
                stats[f"{s.source}: 학습 사용"] += 1
                items.append((f, args.image_weight if s.source == "images" else args.coco_weight, s.source))
                if feats_fp:
                    feats_fp.write(json.dumps({"source": s.source, "ref": s.ref, **f.to_dict()}, ensure_ascii=False) + "\n")
    finally:
        if feats_fp:
            feats_fp.close()

    for k, v in sorted(stats.items()):
        print(f"{k}: {v:,}", file=sys.stderr)

    learned = build_templates(items, max_k=args.max_k)
    existing = json.loads(args.out.read_text(encoding="utf-8")) if args.out.exists() else None
    result, used = merge_with_existing(learned, existing, min_samples=args.min_samples)
    if not used:
        print(f"표본이 {args.min_samples}개 이상인 샷이 없어 템플릿을 저장하지 않았습니다.", file=sys.stderr)
        return 2
    if args.summary_out:
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        lic = license_counts(args.images) if args.images and args.images.exists() else {}
        args.summary_out.write_text(
            render_summary(result, used, dict(sorted(stats.items())), lic, position_table(items)), encoding="utf-8"
        )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"학습된 샷: {', '.join(used)} → {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
