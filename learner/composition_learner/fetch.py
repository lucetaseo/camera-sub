"""자유 라이선스 인물 사진을 최대한 많이 내려받는다.

출처 (둘 다 API 키 없이 사용 가능):
- Openverse (https://openverse.org): CC0·퍼블릭 도메인·CC 라이선스 이미지 검색
- Wikimedia Commons (https://commons.wikimedia.org): 모든 파일이 자유 라이선스

사진마다 출처와 라이선스를 <그룹>/credits.jsonl 에 남긴다.
인스타그램 등 이용약관이 수집을 금지하는 곳은 쓰지 않는다.

사용법:
    python -m composition_learner.fetch --out ../references --per-group 400
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable, Optional

API = "https://api.openverse.org/v1/images/"
COMMONS_API = "https://commons.wikimedia.org/w/api.php"
USER_AGENT = "camera-sub-composition-learner/1.0 (+https://github.com/lucetaseo/camera-sub)"
DEFAULT_LICENSES = "cc0,pdm,by,by-sa"

# 인물 사진 검색어. 샷 종류는 학습할 때 관절 위치로 다시 판단하므로 그룹은 정리용이다.
QUERY_GROUPS: dict[str, list[str]] = {
    "full_body": [
        "full body portrait outdoor", "full length portrait woman", "full length portrait man",
        "street style full body", "woman standing portrait street", "man standing portrait city",
        "fashion portrait outdoor", "tourist posing full body",
    ],
    "half_body": [
        "half body portrait outdoor", "waist up portrait", "environmental portrait", "street portrait",
        "travel portrait", "portrait of a woman in the city", "portrait of a man outdoors", "woman posing travel",
        "man posing travel", "smiling woman portrait park",
    ],
    "close_up": [
        "headshot natural light outdoor", "close up portrait woman", "close up portrait man",
        "portrait natural light", "outdoor headshot", "bust portrait",
    ],
}  # fmt: skip


@dataclass
class Photo:
    id: str
    group: str
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
    thumbnail: str = ""


def parse_results(payload: dict, group: str, min_short_side: int = 480) -> list[Photo]:
    """Openverse 응답에서 쓸 수 있는 세로 사진만 고른다."""
    photos = []
    for r in payload.get("results", []):
        w, h = r.get("width") or 0, r.get("height") or 0
        if not r.get("url") or min(w, h) < min_short_side or h < w:
            continue
        photos.append(
            Photo(
                id="ov-" + r["id"],
                group=group,
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
                thumbnail=r.get("thumbnail") or "",
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


_TOKEN: Optional[str] = None
RETRY_STATUS = {403, 429, 500, 502, 503, 504}


class RateLimited(Exception):
    """재시도 후에도 Openverse 가 요청을 막을 때."""


def _openverse_token() -> Optional[str]:
    """OPENVERSE_CLIENT_ID/SECRET 이 있으면 OAuth 토큰을 받아 요청 한도를 늘린다."""
    global _TOKEN
    cid, secret = os.environ.get("OPENVERSE_CLIENT_ID"), os.environ.get("OPENVERSE_CLIENT_SECRET")
    if _TOKEN or not (cid and secret):
        return _TOKEN
    body = urllib.parse.urlencode(
        {"client_id": cid, "client_secret": secret, "grant_type": "client_credentials"}
    ).encode()
    req = urllib.request.Request(API.replace("images/", "auth_tokens/token/"), data=body, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        _TOKEN = json.loads(resp.read())["access_token"]
    return _TOKEN


def _get(url: str, timeout: float = 30, auth: bool = False) -> bytes:
    headers = {"User-Agent": USER_AGENT}
    token = _openverse_token() if auth else None
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def get_with_retry(url: str, retries: int = 4, backoff: float = 10.0, auth: bool = False, sleep=time.sleep) -> bytes:
    """요청 한도(429)·일시 오류(5xx)·차단(403)이면 점점 길게 기다렸다 다시 시도한다."""
    for attempt in range(retries + 1):
        try:
            return _get(url, auth=auth)
        except urllib.error.HTTPError as e:
            if e.code not in RETRY_STATUS or attempt == retries:
                if e.code in RETRY_STATUS:
                    raise RateLimited(f"HTTP {e.code}") from e
                raise
            retry_after = e.headers.get("Retry-After") if e.headers else None
            wait = float(retry_after) if retry_after and retry_after.isdigit() else backoff * (3**attempt)
            print(f"  HTTP {e.code}, {wait:.0f}초 후 다시 시도", file=sys.stderr)
            sleep(wait)
    raise AssertionError("unreachable")


def search_openverse(
    group: str, queries: Iterable[str], limit: int, licenses: str, delay: float, max_pages: int = 2
) -> list[Photo]:
    seen: dict[str, Photo] = {}
    for q in queries:
        for page in range(1, max_pages + 1):
            if len(seen) >= limit * 2:  # 인물 미검출로 버려질 몫까지 여유 있게
                break
            try:
                payload = json.loads(get_with_retry(build_query_url(q, page, licenses), retries=2, auth=True))
            except RateLimited as e:
                print(f"  Openverse 한도 초과 ({q!r} p{page}): {e} → Openverse 검색 중단", file=sys.stderr)
                return list(seen.values())
            except Exception as e:  # 네트워크 오류나 마지막 페이지 이후
                print(f"  검색 실패 ({q!r} p{page}): {e}", file=sys.stderr)
                break
            for p in parse_results(payload, group):
                seen.setdefault(p.id, p)
            time.sleep(delay)
            if not payload.get("results") or not payload.get("page_count") or page >= payload["page_count"]:
                break
    return list(seen.values())


def fetch_image(p: Photo) -> Optional[bytes]:
    """원본을 받고, 원본 사이트가 막으면 Openverse 썸네일로 받는다."""
    for url in filter(None, [p.url, p.thumbnail]):
        try:
            data = _get(url)
        except Exception as e:
            print(f"  다운로드 실패 {url}: {e}", file=sys.stderr)
            continue
        if len(data) >= 10_000:  # 깨진 파일/플레이스홀더 제외
            return data
    return None


def parse_commons(payload: dict, group: str, min_short_side: int = 480) -> list[Photo]:
    photos = []
    for page in (payload.get("query") or {}).get("pages", {}).values():
        info = (page.get("imageinfo") or [{}])[0]
        w, h = info.get("width") or 0, info.get("height") or 0
        url = info.get("thumburl") or info.get("url")
        if not url or min(w, h) < min_short_side or h < w:
            continue
        meta = info.get("extmetadata") or {}
        val = lambda k: (meta.get(k) or {}).get("value", "")
        photos.append(
            Photo(
                id=f"wc-{page['pageid']}",
                group=group,
                url=url,
                title=page.get("title", ""),
                creator=val("Artist")[:200],
                license=val("LicenseShortName"),
                license_version="",
                license_url=val("LicenseUrl"),
                landing_url=info.get("descriptionurl", ""),
                source="wikimedia_commons",
                width=w,
                height=h,
            )
        )
    return photos


def build_commons_url(query: str, offset: int, limit: int = 50, thumb_width: int = 1024) -> str:
    params = {
        "action": "query",
        "format": "json",
        "generator": "search",
        "gsrsearch": f"{query} filetype:bitmap",
        "gsrnamespace": "6",
        "gsrlimit": str(limit),
        "gsroffset": str(offset),
        "prop": "imageinfo",
        "iiprop": "url|size|extmetadata",
        "iiurlwidth": str(thumb_width),
        "iiextmetadatafilter": "LicenseShortName|LicenseUrl|Artist",
        "maxlag": "5",
    }
    return COMMONS_API + "?" + urllib.parse.urlencode(params)


def search_commons(group: str, queries: Iterable[str], limit: int, delay: float, max_pages: int = 4) -> list[Photo]:
    seen: dict[str, Photo] = {}
    for q in queries:
        for page in range(max_pages):
            if len(seen) >= limit * 2:
                break
            try:
                payload = json.loads(get_with_retry(build_commons_url(q, page * 50), retries=3))
            except Exception as e:
                print(f"  Commons 검색 실패 ({q!r} p{page}): {e}", file=sys.stderr)
                break
            new = parse_commons(payload, group)
            for p in new:
                seen.setdefault(p.id, p)
            time.sleep(delay)
            if "continue" not in payload:
                break
    return list(seen.values())


def count_existing(group_dir: Path) -> int:
    credits = group_dir / "credits.jsonl"
    return sum(1 for l in credits.read_text().splitlines() if l.strip()) if credits.exists() else 0


def download(photos: list[Photo], group_dir: Path, limit: int, delay: float) -> int:
    group_dir.mkdir(parents=True, exist_ok=True)
    credits_path = group_dir / "credits.jsonl"
    existing = {json.loads(l)["id"] for l in credits_path.read_text().splitlines() if l.strip()} if credits_path.exists() else set()
    saved = len(existing)
    with credits_path.open("a", encoding="utf-8") as credits:
        for p in photos:
            if saved >= limit:
                break
            if p.id in existing:
                continue
            data = fetch_image(p)
            if data is None:
                continue
            (group_dir / f"{p.id}.jpg").write_bytes(data)
            credits.write(json.dumps(asdict(p), ensure_ascii=False) + "\n")
            existing.add(p.id)
            saved += 1
            time.sleep(delay)
    return saved


def interleave(*lists: list[Photo]) -> list[Photo]:
    """출처가 한쪽으로 쏠리지 않게 번갈아 섞는다."""
    out = []
    for i in range(max((len(l) for l in lists), default=0)):
        out += [l[i] for l in lists if i < len(l)]
    return out


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="자유 라이선스 인물 사진을 내려받습니다.")
    ap.add_argument("--out", type=Path, default=Path("../references"))
    ap.add_argument("--per-group", type=int, default=400, help="그룹당 최대 사진 수")
    ap.add_argument("--groups", nargs="*", default=list(QUERY_GROUPS))
    ap.add_argument("--sources", nargs="*", default=["commons", "openverse"], choices=["commons", "openverse"])
    ap.add_argument("--licenses", default=DEFAULT_LICENSES, help="Openverse 라이선스 필터")
    ap.add_argument("--delay", type=float, default=2.0, help="검색 요청 사이 대기(초)")
    ap.add_argument("--max-pages", type=int, default=2, help="Openverse 검색어당 최대 페이지 수")
    args = ap.parse_args(argv)

    total = 0
    for group in args.groups:
        if group not in QUERY_GROUPS:
            print(f"알 수 없는 그룹: {group}", file=sys.stderr)
            return 1
        have = count_existing(args.out / group)
        if have >= args.per_group:
            print(f"[{group}] 이미 {have}장 있음 → 건너뜀", file=sys.stderr)
            total += have
            continue
        need = args.per_group - have
        found = []
        if "commons" in args.sources:
            found.append(search_commons(group, QUERY_GROUPS[group], need, delay=0.5))
        if "openverse" in args.sources:
            found.append(search_openverse(group, QUERY_GROUPS[group], need, args.licenses, args.delay, args.max_pages))
        photos = interleave(*found)
        n = download(photos, args.out / group, args.per_group, delay=0.2)
        print(f"[{group}] 후보 {len(photos)}장 ({', '.join(str(len(f)) for f in found)}) → 보유 {n}장", file=sys.stderr)
        total += n
    print(f"전체 {total}장", file=sys.stderr)
    # 이전 실행에서 받아 둔 사진(캐시)만으로도 학습할 수 있으므로 0장이어도 실패로 보지 않는다.
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
