# 구도 카메라 앱 (Flutter)

설명과 실행 방법은 [저장소 README](../README.md) 를 보세요.

- `lib/composition/` 구도 템플릿 파싱과 안내 규칙 (순수 Dart, 테스트 있음)
- `lib/vision/` ML Kit 인물 검출
- `lib/ui/` 카메라 화면, 오버레이, 촬영/저장, 사용 키 입력 화면 (`license_gate.dart`)
- `lib/license/` 사용 기간 키 검증 (순수 Dart, 테스트 있음)
- `assets/templates.json` 구도 템플릿 (learner 결과로 교체)
