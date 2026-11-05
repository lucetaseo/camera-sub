"""Openverse 에서 자유 라이선스 사진을 장면별로 내려받는다.

Openverse(https://openverse.org)는 CC0·퍼블릭 도메인·CC 라이선스 이미지를 모아 둔
검색 서비스로, API 키 없이 쓸 수 있다. 사진마다 출처와 라이선스를 credits.jsonl 에 남긴다.

사용법:
    python -m composition_learner.fetch --out ../references --per-scene 80
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Optional

API = "https://api.openverse.org/v1/images/"
USER_AGENT = "camera-sub-composition-learner/1.0 (+https://github.com/lucetaseo/camera-sub)"
DEFAULT_LICENSES = "cc0,pdm,by,by-sa"

# 장면별 검색어. 인물이 한 명 전신/반신으로 나오는 여행 사진이 잘 걸리도록 고른 문구.
SCENE_QUERIES: dict[str, list[str]] = {
    "beach": ["woman standing on beach", "man standing on beach", "person beach travel", "girl seaside"],
    "landscape": ["hiker mountain view", "person standing landscape", "traveler lake", "woman standing in field"],
    "city": ["woman walking city street", "man standing street travel", "tourist street full body", "person alley"],
    "architecture": ["tourist in front of temple", "person standing castle", "woman archway", "person in front of church"],
    "portrait": ["travel portrait woman outdoor", "travel portrait man outdoor", "half body portrait outdoor"],
}


@dataclass
class Photo:
    id: str
    scene: str
    url: str
    title: str
    creator: str
    license: str
    license_version: str
    license_url: str
    landing_url: str
    source: str
    width: int
    height: int


def parse_results(payload: dict, scene: str, min_short_side: int = 480) -> list[Photo]:
    """Openverse 응답에서 쓸 수 있는 세로 사진만 고른다."""
    photos = []
    for r in payload.get("results", []):
        w, h = r.get("width") or 0, r.get("height") or 0
        if not r.get("url") or min(w, h) < min_short_side or h < w:
            continue
        photos.append(
            Photo(
                id=r["id"],
                scene=scene,
                url=r["url"],
                title=r.get("title") or "",
                creator=r.get("creator") or "",
                license=r.get("license") or "",
                license_version=r.get("license_version") or "",
                license_url=r.get("license_url") or "",
                landing_url=r.get("foreign_landing_url") or "",
                source=r.get("source") or "",
                width=w,
                height=h,
            )
        )
    return photos


def build_query_url(query: str, page: int, licenses: str = DEFAULT_LICENSES, page_size: int = 20) -> str:
    params = {
        "q": query,
        "license": licenses,
        "category": "photograph",
        "aspect_ratio": "tall",
        "size": "medium,large",
        "mature": "false",
        "page_size": str(page_size),
        "page": str(page),
    }
    return API + "?" + urllib.parse.urlencode(params)


def _get(url: str, timeout: float = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def search(scene: str, queries: Iterable[str], limit: int, licenses: str, delay: float) -> list[Photo]:
    seen: dict[str, Photo] = {}
    for q in queries:
        for page in range(1, 6):
            if len(seen) >= limit * 2:  # 인물 미검출로 버려질 몫까지 여유 있게
                break
            try:
                payload = json.loads(_get(build_query_url(q, page, licenses)))
            except Exception as e:  # 네트워크 오류나 마지막 페이지 이후
                print(f"  검색 실패 ({q!r} p{page}): {e}", file=sys.stderr)
                break
            new = parse_results(payload, scene)
            for p in new:
                seen.setdefault(p.id, p)
            time.sleep(delay)
            if not payload.get("results"):
                break
    return list(seen.values())


def download(photos: list[Photo], scene_dir: Path, limit: int, delay: float) -> int:
    scene_dir.mkdir(parents=True, exist_ok=True)
    credits_path = scene_dir / "credits.jsonl"
    existing = {json.loads(l)["id"] for l in credits_path.read_text().splitlines()} if credits_path.exists() else set()
    saved = len(existing)
    with credits_path.open("a", encoding="utf-8") as credits:
        for p in photos:
            if saved >= limit:
                break
            if p.id in existing:
                continue
            target = scene_dir / f"{p.id}.jpg"
            try:
                data = _get(p.url)
            except Exception as e:
                print(f"  다운로드 실패 {p.url}: {e}", file=sys.stderr)
                continue
            if len(data) < 10_000:  # 깨진 파일/플레이스홀더
                continue
            target.write_bytes(data)
            credits.write(json.dumps(asdict(p), ensure_ascii=False) + "\n")
            saved += 1
            time.sleep(delay)
    return saved


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Openverse 에서 장면별 학습용 사진을 내려받습니다.")
    ap.add_argument("--out", type=Path, default=Path("../references"))
    ap.add_argument("--per-scene", type=int, default=80)
    ap.add_argument("--scenes", nargs="*", default=list(SCENE_QUERIES), help="받을 장면 (기본: 전부)")
    ap.add_argument("--licenses", default=DEFAULT_LICENSES, help="Openverse 라이선스 필터")
    ap.add_argument("--delay", type=float, default=0.5, help="요청 사이 대기(초)")
    args = ap.parse_args(argv)

    total = 0
    for scene in args.scenes:
        if scene not in SCENE_QUERIES:
            print(f"알 수 없는 장면: {scene}", file=sys.stderr)
            return 1
        photos = search(scene, SCENE_QUERIES[scene], args.per_scene, args.licenses, args.delay)
        n = download(photos, args.out / scene, args.per_scene, args.delay)
        print(f"[{scene}] 후보 {len(photos)}장 → 저장 {n}장", file=sys.stderr)
        total += n
    return 0 if total else 1


if __name__ == "__main__":
    raise SystemExit(main())
