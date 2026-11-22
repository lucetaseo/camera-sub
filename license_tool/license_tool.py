"""구도 카메라 사용 기간 키 발급 도구.

    python license_tool.py init                       # 처음 한 번: 개인키 만들고 앱에 공개키 넣기
    python license_tool.py issue --name 홍길동          # 오늘부터 30일짜리 키 발급
    python license_tool.py issue --name 홍길동 --days 31
    python license_tool.py issue --name 홍길동 --until 2026-12-31   # 그날 23:59:59 (한국 시간) 까지
    python license_tool.py show CS1-....               # 키 내용과 서명 확인

키 형식과 앱 쪽 검증은 app/lib/license/license.dart 를 보세요.
private_key.pem 은 절대 저장소에 올리거나 남에게 주지 마세요. 이 파일이 있으면 누구나 키를 만들 수 있습니다.
"""

from __future__ import annotations

import argparse
import base64
import csv
import json
import secrets
import sys
from datetime import datetime, time, timedelta, timezone
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

HERE = Path(__file__).resolve().parent
PRIVATE_KEY = HERE / "private_key.pem"
ISSUED_LOG = HERE / "issued.csv"
DART_PUBLIC_KEY = HERE.parent / "app" / "lib" / "license" / "license_public_key.dart"

PREFIX = "CS1-"
KST = timezone(timedelta(hours=9))


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def make_key(private_key: Ed25519PrivateKey, name: str, issued_at: datetime, expires_at: datetime) -> str:
    payload = json.dumps(
        {
            "v": 1,
            "id": secrets.token_hex(4),
            "name": name,
            "iat": int(issued_at.timestamp()),
            "exp": int(expires_at.timestamp()),
        },
        separators=(",", ":"),
    ).encode()
    return PREFIX + _b64(payload) + "." + _b64(private_key.sign(payload))


def read_key(public_key: Ed25519PublicKey, key: str) -> dict:
    """키를 풀어서 payload 를 돌려준다. 형식이 틀리거나 서명이 안 맞으면 ValueError."""
    key = "".join(key.split())
    if not key.startswith(PREFIX):
        raise ValueError("CS1- 로 시작하지 않습니다")
    try:
        payload_b64, sig_b64 = key[len(PREFIX):].split(".")
        payload, sig = _unb64(payload_b64), _unb64(sig_b64)
    except ValueError as e:
        raise ValueError("키 형식이 올바르지 않습니다") from e
    try:
        public_key.verify(sig, payload)
    except InvalidSignature as e:
        raise ValueError("서명이 맞지 않습니다 (다른 개인키로 만들었거나 변조된 키)") from e
    return json.loads(payload)


def expiry_from_args(now: datetime, days: int | None, until: str | None) -> datetime:
    if until:
        day = datetime.strptime(until, "%Y-%m-%d").date()
        return datetime.combine(day, time(23, 59, 59), tzinfo=KST)
    return now + timedelta(days=days or 30)


def public_key_dart(public_key: Ed25519PublicKey) -> str:
    raw = public_key.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return (
        "// license_tool/license_tool.py init 이 자동으로 덮어쓰는 파일입니다. 직접 고치지 마세요.\n"
        "// 비어 있으면 앱은 어떤 키도 받지 않습니다.\n"
        f"const licensePublicKey = <int>[{', '.join(str(b) for b in raw)}];\n"
    )


def load_private_key() -> Ed25519PrivateKey:
    if not PRIVATE_KEY.exists():
        sys.exit(f"{PRIVATE_KEY} 가 없습니다. 먼저 `python license_tool.py init` 을 실행하세요.")
    key = serialization.load_pem_private_key(PRIVATE_KEY.read_bytes(), password=None)
    assert isinstance(key, Ed25519PrivateKey)
    return key


def cmd_init(args: argparse.Namespace) -> None:
    if PRIVATE_KEY.exists() and not args.force:
        sys.exit(
            f"{PRIVATE_KEY} 가 이미 있습니다. 새로 만들면 지금까지 발급한 키가 모두 무효가 됩니다.\n"
            "정말 새로 만들려면 --force 를 붙이세요."
        )
    key = Ed25519PrivateKey.generate()
    PRIVATE_KEY.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    PRIVATE_KEY.chmod(0o600)
    DART_PUBLIC_KEY.write_text(public_key_dart(key.public_key()), encoding="utf-8")
    print(f"개인키 저장: {PRIVATE_KEY}  ← 안전한 곳에 백업하고 절대 공유하지 마세요")
    print(f"공개키를 앱에 넣었습니다: {DART_PUBLIC_KEY}")
    print("이제 앱을 다시 빌드해서 배포하세요.")


def cmd_issue(args: argparse.Namespace) -> None:
    key = load_private_key()
    now = datetime.now(timezone.utc)
    exp = expiry_from_args(now, args.days, args.until)
    if exp <= now:
        sys.exit("만료일이 지금보다 이전입니다.")
    text = make_key(key, args.name, now, exp)
    info = read_key(key.public_key(), text)
    new_file = not ISSUED_LOG.exists()
    with ISSUED_LOG.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new_file:
            w.writerow(["id", "name", "issued_kst", "expires_kst", "key"])
        w.writerow([info["id"], args.name, now.astimezone(KST).isoformat(timespec="seconds"),
                    exp.astimezone(KST).isoformat(timespec="seconds"), text])
    print(f"# {args.name} · {exp.astimezone(KST):%Y-%m-%d %H:%M} (한국 시간) 까지", file=sys.stderr)
    print(text)


def cmd_show(args: argparse.Namespace) -> None:
    try:
        info = read_key(load_private_key().public_key(), args.key)
    except ValueError as e:
        sys.exit(f"유효하지 않은 키: {e}")
    fmt = lambda ts: datetime.fromtimestamp(ts, KST).strftime("%Y-%m-%d %H:%M:%S")
    left = datetime.fromtimestamp(info["exp"], timezone.utc) - datetime.now(timezone.utc)
    print(f"id      {info['id']}")
    print(f"이름     {info['name']}")
    print(f"발급     {fmt(info['iat'])} (KST)")
    print(f"만료     {fmt(info['exp'])} (KST)")
    print(f"상태     {'사용 가능, ' + str(left.days) + '일 남음' if left.total_seconds() > 0 else '만료됨'}")


def main(argv: list[str] | None = None) -> None:
    p = argparse.ArgumentParser(description="구도 카메라 사용 기간 키 발급")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("init", help="개인키 생성 + 앱에 공개키 넣기")
    s.add_argument("--force", action="store_true")
    s.set_defaults(func=cmd_init)
    s = sub.add_parser("issue", help="키 발급")
    s.add_argument("--name", required=True, help="받는 사람 (메모용, 키 안에 들어감)")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--days", type=int, help="지금부터 며칠 (기본 30)")
    g.add_argument("--until", help="YYYY-MM-DD, 그날 23:59:59 한국 시간까지")
    s.set_defaults(func=cmd_issue)
    s = sub.add_parser("show", help="키 확인")
    s.add_argument("key")
    s.set_defaults(func=cmd_show)
    args = p.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
