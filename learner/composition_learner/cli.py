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

from .cluster import build_templates
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
    args = p.parse_args(argv)

    scene_dirs = sorted(d for d in args.references.iterdir() if d.is_dir())
    if not scene_dirs:
        print("장면 폴더가 없습니다. 예: references/beach/*.jpg", file=sys.stderr)
        return 1

    extractor = FeatureExtractor(ensure_model(args.model))
    features = []
    try:
        for scene_dir in scene_dirs:
            images = sorted(f for f in scene_dir.iterdir() if f.suffix.lower() in IMAGE_EXTS)
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

    result = build_templates(features, max_k=args.max_k)
    if not result["scenes"]:
        # 빈 파일로 덮어쓰면 앱이 쓸 템플릿이 없어지므로 저장하지 않는다.
        print("인물이 검출된 사진이 없어 템플릿을 저장하지 않았습니다.", file=sys.stderr)
        return 2
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    total = sum(len(s["templates"]) for s in result["scenes"])
    print(f"템플릿 {total}개 저장: {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
