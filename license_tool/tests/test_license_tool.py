import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

import license_tool as lt

FIXTURES = json.loads((Path(__file__).resolve().parents[2] / "shared" / "license_fixtures.json").read_text("utf-8"))
TEST_KEY = Ed25519PrivateKey.from_private_bytes(bytes(range(32)))


def test_roundtrip():
    now = datetime(2026, 11, 22, tzinfo=timezone.utc)
    key = lt.make_key(TEST_KEY, "김철수", now, now + timedelta(days=30))
    info = lt.read_key(TEST_KEY.public_key(), key)
    assert info["name"] == "김철수"
    assert info["exp"] - info["iat"] == 30 * 86400


def test_fixture_matches_dart_side():
    info = lt.read_key(TEST_KEY.public_key(), FIXTURES["valid"])
    assert info["exp"] == int(datetime(2026, 12, 1, tzinfo=timezone.utc).timestamp())


def test_whitespace_in_pasted_key_is_ignored():
    k = FIXTURES["valid"]
    assert lt.read_key(TEST_KEY.public_key(), k[:20] + "\n " + k[20:])["name"] == "홍길동"


@pytest.mark.parametrize("key", [
    FIXTURES["otherSigner"],
    FIXTURES["valid"].replace("CS1-eyJ2", "CS1-eyJ3"),  # payload 변조
    "hello",
])
def test_rejects_bad_keys(key):
    with pytest.raises(ValueError):
        lt.read_key(TEST_KEY.public_key(), key)


def test_until_is_end_of_day_kst():
    exp = lt.expiry_from_args(datetime.now(timezone.utc), None, "2026-12-31")
    assert exp.astimezone(lt.KST).strftime("%Y-%m-%d %H:%M:%S") == "2026-12-31 23:59:59"


def test_public_key_dart_has_32_bytes():
    src = lt.public_key_dart(TEST_KEY.public_key())
    assert src.split("[")[1].split("]")[0].count(",") == 31
