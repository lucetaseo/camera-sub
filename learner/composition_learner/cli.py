"""명령줄 도구.

사용법:
    python -m composition_learner.cli ../references --out ../app/assets/templates.json

references/ 아래에 장면별 폴더(beach/, city/ ...)를 만들고, 사용 허락을 받은 사진을 넣는다.
"""
from __future__ import annotations

import argparse
import json
import sys
import urllib.request
from pathlib import Path

from .cluster import build_templates, merge_with_existing, render_summary
from .features import FeatureExtractor

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


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="레퍼런스 사진에서 구도 템플릿을 학습합니다.")
    p.add_argument("references", type=Path, help="장면별 하위 폴더가 있는 레퍼런스 사진 폴더")
    p.add_argument("--out", type=Path, default=Path("templates.json"))
    p.add_argument("--features-out", type=Path, help="사진별 특징을 JSONL 로 저장 (확인용)")
    p.add_argument("--model", type=Path, default=Path(__file__).resolve().parent.parent / "models" / "pose_landmarker_lite.task")
    p.add_argument("--max-k", type=int, default=3, help="장면당 최대 템플릿 수")
    p.add_argument("--min-samples", type=int, default=8, help="이보다 인물 사진이 적은 장면은 기존 템플릿 유지")
    p.add_argument("--summary-out", type=Path, help="학습 요약(Markdown) 저장 경로")
    args = p.parse_args(argv)

    scene_dirs = sorted(d for d in args.references.iterdir() if d.is_dir())
    if not scene_dirs:
        print("장면 폴더가 없습니다. 예: references/beach/*.jpg", file=sys.stderr)
        return 1

    extractor = FeatureExtractor(ensure_model(args.model))
    features = []
    image_counts: dict[str, int] = {}
    try:
        for scene_dir in scene_dirs:
            images = sorted(f for f in scene_dir.iterdir() if f.suffix.lower() in IMAGE_EXTS)
            image_counts[scene_dir.name] = len(images)
            found = 0
            for img in images:
                f = extractor.extract(img, scene_dir.name)
                if f is None:
                    continue
                features.append(f)
                found += f.has_subject
            print(f"[{scene_dir.name}] 사진 {len(images)}장 중 인물 검출 {found}장", file=sys.stderr)
    finally:
        extractor.close()

    if args.features_out:
        with args.features_out.open("w", encoding="utf-8") as fp:
            for f in features:
                fp.write(json.dumps(f.to_dict(), ensure_ascii=False) + "\n")

    learned = build_templates(features, max_k=args.max_k)
    existing = json.loads(args.out.read_text(encoding="utf-8")) if args.out.exists() else None
    result, used = merge_with_existing(learned, existing, min_samples=args.min_samples)
    if not used:
        # 학습된 장면이 하나도 없으면 기존 파일을 그대로 둔다.
        print(f"인물 사진이 {args.min_samples}장 이상인 장면이 없어 템플릿을 저장하지 않았습니다.", file=sys.stderr)
        return 2
    if args.summary_out:
        args.summary_out.parent.mkdir(parents=True, exist_ok=True)
        args.summary_out.write_text(
            render_summary(result, used, image_counts, _license_counts(args.references)), encoding="utf-8"
        )
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    total = sum(len(s["templates"]) for s in result["scenes"])
    print(f"템플릿 {total}개 저장: {args.out}", file=sys.stderr)
    return 0


def _license_counts(references: Path) -> dict[str, int]:
    """fetch 가 남긴 credits.jsonl 에서 라이선스별 장수를 센다."""
    counts: dict[str, int] = {}
    for credits in references.glob("*/credits.jsonl"):
        for line in credits.read_text(encoding="utf-8").splitlines():
            if line.strip():
                lic = json.loads(line).get("license", "?")
                counts[lic] = counts.get(lic, 0) + 1
    return counts


if __name__ == "__main__":
    raise SystemExit(main())
