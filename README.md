# 구도 카메라 (camera-sub)

**인물 사진**을 찍는 사람에게 실시간으로 구도를 안내하고, 그 자리에서 바로 촬영·저장하는 휴대폰 앱입니다.
구도 규칙은 공개 데이터와 자유 라이선스 인물 사진에서 **학습**합니다.

```
COCO 관절 데이터 ┐
Wikimedia Commons ├─► learner/ (샷 종류별 인물 구도 학습) ─► app/assets/templates.json ─► app/ (Flutter 앱)
Openverse 사진    ┘
```

## 앱 기능 (`app/`)

카메라가 인물의 관절(눈·코·귀·어깨·팔꿈치·손목·골반·무릎·발목)을 실시간으로 찾아서 다음을 판단합니다.

| 판단 | 방법 |
|---|---|
| **샷 종류** 전신 / 무릎샷 / 반신 / 상반신 / 얼굴 클로즈업 | 화면 안에 보이는 가장 아래 관절 |
| **시선 방향** | 코가 귀(눈)의 가운데에서 어느 쪽으로 치우쳤는지 |
| **눈높이**, 얼굴 위치·크기 | 눈·어깨 위치 |
| **관절 잘림**, 머리 잘림 | 화면 끝에 걸친 관절 |

그리고 학습한 구도 템플릿과 비교해서 안내합니다.

- "시선 앞(오른쪽)에 여백을 두세요 · 카메라를 오른쪽으로 조금" ← 시선 방향 쪽 여백 (lead room)
- "눈높이가 낮아요 · 카메라를 살짝 아래로" ← 눈높이를 위 1/3 근처에
- "무릎에서 잘려요 · 조금 더 아래까지 담거나 그보다 위에서 자르세요" ← 관절에서 자르지 않기
- "머리가 잘려요", "인물이 작아요 · 반 걸음 앞으로", "수평이 3° 기울었어요"
- 구도가 맞으면 "좋아요! 지금 찍으세요" + 셔터 테두리 초록색, 구도 점수(0~100)

화면에는 삼분할 격자, **목표 얼굴 위치(점선 원)와 목표 눈높이 선**, 지금 얼굴 위치와 시선 방향 화살표, 잘림 경고(빨간 띠), 수평계가 그려집니다.

- **샷 선택**: "자동"이면 지금 찍히는 샷 기준으로 안내, "전신"을 고르면 전신이 되도록 "뒤로 물러나세요"부터 안내
- 구도 템플릿 자동 선택, 탭해서 고정 (템플릿은 오른쪽을 보는 인물 기준이고, 왼쪽을 보면 자동으로 좌우 반전)
- **배경 장면 인식** (바다/풍경/도시/건물): 건물 배경이면 가운데 대칭 구도를 우선
- **촬영**: 셔터 → 갤러리 `CameraSub` 앨범에 저장, 마지막 사진 썸네일, 핀치 줌, 플래시, 격자 켜기/끄기

모든 인식은 휴대폰 안(ML Kit)에서 하므로 인터넷이 필요 없습니다.

### 실행

[Flutter SDK](https://docs.flutter.dev/get-started/install) 설치 후 실제 휴대폰을 USB 로 연결하고:

```bash
cd app && flutter pub get && flutter run
```

- Android 7.0 이상 실기기, iOS 15.5 이상 **실기기** (ML Kit 는 iOS 시뮬레이터 미지원, Xcode 서명 설정 필요)

```bash
cd app && flutter test
```

## 구도 학습 (`learner/`)

### 데이터

| 출처 | 내용 | 양 |
|---|---|---|
| [COCO 2017](https://cocodataset.org) 사람 관절 주석 | 사람이 직접 표시한 17개 관절 좌표. 사진은 받지 않고 숫자만 사용 | 세로 사진 속 주인공 수천 명 |
| [Wikimedia Commons](https://commons.wikimedia.org) | 자유 라이선스 인물 사진 (전신·반신·클로즈업 검색어 24개) | 그룹당 최대 400장, 실행할수록 누적 |
| [Openverse](https://openverse.org) | CC0·퍼블릭 도메인·CC BY(-SA) 인물 사진 | 요청 한도 안에서 누적 |

인스타그램처럼 이용약관이 수집을 금지하는 곳은 쓰지 않습니다.

### 학습 방법

1. 사진마다 주인공 한 명을 고릅니다 (두 번째 사람보다 2배 이상 커야 함, 군중 사진 제외).
2. 관절에서 샷 종류, 얼굴 위치, 눈높이, 얼굴 크기, 시선 방향을 계산합니다.
3. **관절·머리가 잘린 사진은 학습에서 뺍니다** (흔히 피하는 구도).
4. 왼쪽을 보는 사진은 좌우를 뒤집어 "오른쪽을 보는" 기준으로 맞춥니다 → 시선 앞 여백이 그대로 학습됩니다.
5. 샷 종류별로 KMeans 군집화해서 대표 구도 2~3개를 템플릿으로 만듭니다. 검색한 인물 사진은 COCO(일상 스냅)보다 3배 가중치.

계산 방식은 `learner/composition_learner/portrait.py` 와 `app/lib/composition/portrait.dart` 가 똑같고,
`shared/portrait_fixtures.json` 테스트로 양쪽이 같은 결과를 내는지 확인합니다.

### 방법 1: GitHub Actions 자동 학습

`.github/workflows/train-templates.yml` 이 데이터 수집 → 학습 → 앱 테스트 → `app/assets/templates.json` 과
`learner/reports/training_summary.md` 커밋까지 합니다. `learner/` 가 바뀌어 push 되면 자동으로 돌고,
Actions 탭의 **Run workflow** 로도 돌릴 수 있습니다. 받은 사진은 Actions 캐시에 쌓여 다음 실행에서 이어집니다.
(선택) 저장소 Secrets 에 `OPENVERSE_CLIENT_ID`/`OPENVERSE_CLIENT_SECRET` 을 넣으면 Openverse 요청 한도가 늘어납니다.

### 방법 2: 직접 실행

```bash
cd learner
pip install -r requirements.txt
python -m composition_learner.fetch --out ../references --per-group 400
python -m composition_learner.cli --images ../references \
  --coco path/to/person_keypoints_train2017.json path/to/person_keypoints_val2017.json \
  --out ../app/assets/templates.json --summary-out reports/training_summary.md
python -m pytest
```

- COCO 주석: http://images.cocodataset.org/annotations/annotations_trainval2017.zip 의 `person_keypoints_*.json`
- Linux 에서 `libEGL.so.1` 오류가 나면 `apt-get install libegl1 libgles2 libgl1`
- 표본이 20개 미만인 샷은 기존 템플릿을 유지합니다.

> ⚠️ 직접 넣는 사진은 사용 허락을 받은 것만 쓰세요. [references/README.md](references/README.md)

## 다음 단계 아이디어

- 로우앵글 안내 (휴대폰 기울기로 카메라 높이 판단: 전신은 무릎 높이에서)
- 2인 이상 단체 사진 구도
- 포즈 추천 (손 위치, 체중 이동)
