# 구도 카메라 (camera-sub)

사진을 찍는 사람에게 **실시간으로 구도를 안내하고, 그 자리에서 바로 촬영·저장**까지 하는 휴대폰 앱입니다.
구도 규칙은 레퍼런스 사진에서 **학습**해서 앱에 넣습니다.

```
references/ (사진)  ──►  learner/ (Python, 구도 학습)  ──►  app/assets/templates.json  ──►  app/ (Flutter 앱)
```

## 앱 기능 (`app/`)

- 실시간 카메라 화면 위에
  - 삼분할 격자
  - **목표 구도 실루엣** (어디에, 얼마나 크게 서야 하는지)
  - 지금 인물 위치 박스와 목표까지의 화살표
  - 수평계 (2° 이내면 초록색)
  - 목표 수평선 위치 (바다·풍경 템플릿)
- 안내 문구 + 구도 점수 (0~100)
  - "수평이 4° 기울었어요 · 왼쪽을 살짝 올리세요"
  - "인물이 작아요 · 한 걸음 앞으로", "카메라를 오른쪽으로 조금 돌리세요"
  - "머리가 잘려요", "발끝이 잘려요"
  - 구도가 맞으면 "좋아요! 지금 찍으세요" + 셔터 테두리가 초록색으로
- **장면 자동 인식**: 카메라가 바다·풍경·도시·건물·인물 클로즈업을 스스로 판단해서 그에 맞는 구도로 안내
  (ML Kit 이미지 라벨링, 0.8초마다 한 번, 같은 결과가 두 번 연속 나와야 바뀌어서 깜빡이지 않음)
  - 인물이 화면 높이의 60% 이상이면 인물 클로즈업
  - 라벨 → 장면 규칙은 `app/assets/scene_rules.json` 에서 고칠 수 있음
  - 원하면 장면을 직접 골라 고정할 수도 있음
- 구도 템플릿 자동 선택 (지금 화면과 가장 가까운 구도) 또는 탭해서 고정
- **촬영**: 셔터 → 갤러리 `CameraSub` 앨범에 저장, 마지막 사진 썸네일 (탭하면 갤러리 열기)
- 핀치 줌, 플래시(자동/끄기), 격자 켜기/끄기

인물 검출은 Google ML Kit 포즈 검출을 **휴대폰 안에서** 돌리므로 인터넷이 필요 없습니다.

### 실행

[Flutter SDK](https://docs.flutter.dev/get-started/install) 설치 후, 실제 휴대폰을 USB 로 연결하고:

```bash
cd app
flutter pub get
flutter run
```

- Android: Android 7.0 이상 실기기
- iOS: iOS 15.5 이상 **실기기** (ML Kit 는 iOS 시뮬레이터를 지원하지 않음), Xcode 에서 서명(Team) 설정 필요
- 에뮬레이터/시뮬레이터에서는 카메라·인물 검출이 제대로 동작하지 않습니다.

### 테스트

```bash
cd app && flutter test
```

## 구도 학습 (`learner/`)

### 방법 1: GitHub Actions 가 자동으로 학습 (사진 준비 필요 없음)

`.github/workflows/train-templates.yml` 이
1. [Openverse](https://openverse.org) 에서 장면별 **자유 라이선스(CC0, 퍼블릭 도메인, CC BY, CC BY-SA) 세로 사진**을 내려받고
2. 구도를 학습해서
3. `app/assets/templates.json` 과 학습 요약 `learner/reports/training_summary.md` 를 브랜치에 커밋합니다.

`learner/` 가 바뀌어 push 될 때 자동으로 돌고, GitHub 의 Actions 탭에서 **Run workflow** 로 직접 돌릴 수도 있습니다
(장면당 사진 수 조절 가능). 사진은 저장소에 올리지 않고, 사진별 출처는 실행 결과 Artifacts(`credits.jsonl`)에 30일간 보관됩니다.
인물 사진이 8장 미만인 장면은 기존 기본 규칙을 유지합니다.

### 방법 2: 직접 고른 사진으로 학습

레퍼런스 사진마다 다음 특징을 뽑습니다.

| 특징 | 방법 |
|---|---|
| 인물 중심 위치 (x, y), 인물 크기(키/화면 높이), 머리 위 여백 | MediaPipe 포즈 랜드마크 |
| 수평선 위치·기울기 | OpenCV 엣지 + 허프 직선 |

그다음 장면별로 KMeans 군집화해서 자주 쓰이는 구도 2~3개를 **템플릿**(목표 위치 + 허용 오차)으로 만듭니다.

```bash
cd learner
pip install -r requirements.txt
# (선택) Openverse 에서 사진 받기
python -m composition_learner.fetch --out ../references --per-scene 80
# 학습
python -m composition_learner.cli ../references --out ../app/assets/templates.json --summary-out reports/training_summary.md
pytest
```

- 처음 실행할 때 MediaPipe 포즈 모델(약 5MB)을 `learner/models/` 에 내려받습니다.
- Linux 서버에서 `libEGL.so.1` 오류가 나면 `apt-get install libegl1 libgles2` 를 설치하세요.
- 학습 결과가 비어 있으면 기존 `templates.json` 을 덮어쓰지 않습니다.
- 지금 `app/assets/templates.json` 에는 여행 사진에서 흔히 쓰는 구도 규칙(삼분할, 작은 인물+넓은 배경,
  대칭, 수평선 1/3 등)으로 직접 만든 기본 템플릿이 들어 있습니다.

> ⚠️ 레퍼런스 사진은 사용 허락을 받은 것만 쓰세요. 자세한 내용은 [references/README.md](references/README.md).

## 다음 단계 아이디어

- 휴대폰 높이(로우앵글) 안내: 기기 기울기(pitch) 활용
- 여러 명 단체 사진 구도
- 리딩라인(길·난간) 검출
- 사람 없이 찍는 풍경 사진 구도 (수평선·소실점 기준)
