"""인물 사진의 구도 특징.

입력은 COCO 17개 관절 이름으로 된 keypoint 사전이다. (MediaPipe/ML Kit 33개 랜드마크도 같은 이름으로 바꿔 쓴다.)
좌표는 사진 크기로 나눈 0~1 값이며, 화면 밖으로 추정된 점은 0~1 을 벗어날 수 있다.

앱(app/lib/composition/portrait.dart)이 같은 계산을 한다. 둘 중 하나를 바꾸면
shared/portrait_fixtures.json 테스트가 양쪽에서 깨지므로 함께 고쳐야 한다.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from typing import Mapping, Optional, Sequence

KEYPOINTS = [
    "nose", "left_eye", "right_eye", "left_ear", "right_ear",
    "left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "left_wrist", "right_wrist",
    "left_hip", "right_hip", "left_knee", "right_knee", "left_ankle", "right_ankle",
]  # fmt: skip

# MediaPipe / ML Kit 33개 랜드마크 인덱스 → COCO 이름
MEDIAPIPE_INDEX = {
    "nose": 0, "left_eye": 2, "right_eye": 5, "left_ear": 7, "right_ear": 8,
    "left_shoulder": 11, "right_shoulder": 12, "left_elbow": 13, "right_elbow": 14,
    "left_wrist": 15, "right_wrist": 16, "left_hip": 23, "right_hip": 24,
    "left_knee": 25, "right_knee": 26, "left_ankle": 27, "right_ankle": 28,
}  # fmt: skip

# 가까이 찍을수록 아래 관절부터 화면 밖으로 나간다.
SHOT_TYPES = ["full_body", "knee", "waist", "chest", "face"]
SHOT_LABELS = {"full_body": "전신", "knee": "무릎샷", "waist": "반신", "chest": "상반신", "face": "얼굴 클로즈업"}

# 화면 아래 끝이 이 관절 근처를 지나면 '관절에서 잘린' 사진 (인물 사진에서 피하는 구도)
CUT_JOINTS = ["left_knee", "right_knee", "left_ankle", "right_ankle", "left_wrist", "right_wrist", "left_elbow", "right_elbow"]
CUT_MARGIN = 0.035

FACE_TURN_THRESHOLD = 0.12


@dataclass(frozen=True)
class Kp:
    x: float
    y: float
    visible: bool


@dataclass
class PortraitFeatures:
    shot: str
    head_x: float  # 얼굴 중심 x
    eye_y: float  # 눈높이 y
    head_size: float  # 눈~어깨 세로 거리 (화면 높이 대비). 크면 가까이 찍은 것
    top_y: float  # 머리 꼭대기 추정 y (0 보다 작으면 머리가 잘림)
    face_dir: int  # -1: 화면 왼쪽을 봄, 0: 정면, 1: 화면 오른쪽을 봄
    joint_cut: Optional[str]  # 화면 아래 끝에서 잘린 관절 이름

    @property
    def canonical_x(self) -> float:
        """왼쪽을 보는 사진은 좌우를 뒤집어 '오른쪽을 보는' 기준으로 맞춘 x."""
        return 1 - self.head_x if self.face_dir < 0 else self.head_x

    def to_dict(self) -> dict:
        d = asdict(self)
        d["canonical_x"] = self.canonical_x
        return d


def _in_frame(p: Optional[Kp], margin: float = 0.01) -> bool:
    return p is not None and p.visible and -margin <= p.x <= 1 + margin and -margin <= p.y <= 1 + margin


def _mean(vals: Sequence[float]) -> Optional[float]:
    return sum(vals) / len(vals) if vals else None


def compute_features(kps: Mapping[str, Kp]) -> Optional[PortraitFeatures]:
    """관절 위치로 인물 구도 특징을 계산한다. 얼굴이 화면에 없으면 None."""
    g = lambda n: kps.get(n)
    seen = lambda n: _in_frame(g(n))

    eyes = [g(n) for n in ("left_eye", "right_eye") if seen(n)]
    head_pts = eyes + ([g("nose")] if seen("nose") else [])
    if not head_pts:
        return None
    eye_y = _mean([p.y for p in eyes]) if eyes else g("nose").y
    head_x = _mean([p.x for p in head_pts])

    # 얼굴 크기: 눈~어깨 세로 거리. 어깨가 화면 밖이면 (클로즈업) 화면 밖 추정값도 쓴다.
    shoulders = [g(n) for n in ("left_shoulder", "right_shoulder") if g(n) is not None and g(n).visible]
    head_size = None
    if shoulders:
        head_size = _mean([p.y for p in shoulders]) - eye_y
    if head_size is None or head_size <= 0.01:
        ears = [g(n) for n in ("left_ear", "right_ear") if seen(n)]
        span_pts = ears if len(ears) == 2 else eyes
        if len(span_pts) == 2:
            head_size = abs(span_pts[0].x - span_pts[1].x) * 1.6
    if head_size is None or head_size <= 0.01:
        return None

    # 샷 종류: 화면 안에 보이는 가장 아래 관절
    def any_seen(*names: str) -> bool:
        return any(seen(n) for n in names)

    if any_seen("left_ankle", "right_ankle"):
        shot = "full_body"
    elif any_seen("left_knee", "right_knee"):
        shot = "knee"
    elif any_seen("left_hip", "right_hip"):
        shot = "waist"
    elif any_seen("left_shoulder", "right_shoulder"):
        shot = "chest"
    else:
        shot = "face"

    # 얼굴 방향: 코가 귀(없으면 눈)의 가운데보다 어느 쪽에 있는지
    face_dir = 0
    if seen("nose"):
        ears = [g(n) for n in ("left_ear", "right_ear") if seen(n)]
        nose = g("nose")
        if len(ears) == 1:
            face_dir = 1 if nose.x > ears[0].x else -1
        else:
            ref = ears if len(ears) == 2 else eyes
            if len(ref) == 2:
                width = max(abs(ref[0].x - ref[1].x), head_size * 0.3)
                off = (nose.x - (ref[0].x + ref[1].x) / 2) / width
                face_dir = 1 if off > FACE_TURN_THRESHOLD else -1 if off < -FACE_TURN_THRESHOLD else 0

    # 관절에서 잘림: 화면 아래 끝(y=1) 근처에 관절이 걸쳐 있음
    joint_cut = None
    for n in CUT_JOINTS:
        p = g(n)
        if p is not None and p.visible and 0 <= p.x <= 1 and abs(p.y - 1.0) < CUT_MARGIN:
            joint_cut = n
            break

    return PortraitFeatures(
        shot=shot,
        head_x=head_x,
        eye_y=eye_y,
        head_size=head_size,
        top_y=eye_y - head_size * 0.55,
        face_dir=face_dir,
        joint_cut=joint_cut,
    )


def is_good_composition(f: PortraitFeatures) -> bool:
    """학습에 쓸 만한 사진인지 (흔히 피하는 구도는 뺀다)."""
    head_ok = f.top_y >= -0.02 or f.shot == "face"  # 얼굴 클로즈업은 이마가 잘려도 흔한 구도
    return f.joint_cut is None and head_ok and 0.03 <= f.head_x <= 0.97 and 0.03 <= f.eye_y <= 0.9
