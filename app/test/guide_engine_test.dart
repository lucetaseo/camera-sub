import 'dart:io';

import 'package:camera_sub/composition/guide_engine.dart';
import 'package:camera_sub/composition/portrait.dart';
import 'package:camera_sub/composition/templates.dart';
import 'package:flutter_test/flutter_test.dart';

const left = ShotTemplate(id: 'waist-1', description: '시선 앞 여백', subjectCx: 0.38, eyeY: 0.3, headSize: 0.16, tolSize: 0.024);
const center = ShotTemplate(id: 'waist-2', description: '가운데', subjectCx: 0.5, eyeY: 0.31, headSize: 0.16, tolSize: 0.024);
const fullT = ShotTemplate(id: 'full_body-1', description: '전신', subjectCx: 0.36, eyeY: 0.24, headSize: 0.075, tolSize: 0.012);
const shots = [
  Shot(id: 'full_body', label: '전신', templates: [fullT]),
  Shot(id: 'waist', label: '반신', templates: [left, center]),
];

PortraitFeatures f({
  String shot = 'waist',
  double x = 0.38,
  double eye = 0.3,
  double size = 0.16,
  int dir = 1,
  String? cut,
  double? top,
}) =>
    PortraitFeatures(
      shot: shot,
      headX: x,
      eyeY: eye,
      headSize: size,
      topY: top ?? eye - size * 0.55,
      faceDir: dir,
      jointCut: cut,
    );

void main() {
  const engine = GuideEngine();
  List<HintAction> actions(GuideResult r) => r.hints.map((h) => h.action).toList();

  test('구도가 맞으면 촬영 준비 완료', () {
    final r = engine.evaluate(shots: shots, subject: f(), rollDeg: 0.5);
    expect(r.ready, isTrue);
    expect(r.template.id, 'waist-1');
    expect(actions(r), [HintAction.ready]);
    expect(r.score, greaterThan(90));
  });

  test('왼쪽을 보는 인물은 템플릿을 좌우 반전해서 비교한다', () {
    final r = engine.evaluate(shots: shots, subject: f(x: 0.62, dir: -1), rollDeg: 0);
    expect(r.targetX, closeTo(0.62, 1e-9));
    expect(r.ready, isTrue);
  });

  test('시선 앞 여백이 없으면 시선 방향으로 카메라를 돌리라고 안내', () {
    // 오른쪽을 보는데 얼굴이 오른쪽에 붙어 있음 → 템플릿(0.38) 기준으로 카메라를 오른쪽으로
    final r = engine.evaluate(shots: shots, subject: f(x: 0.6), rollDeg: 0, lockedTemplate: left);
    expect(actions(r), [HintAction.panRight]);
    expect(r.hints.first.message, contains('시선 앞(오른쪽)'));
    final r2 = engine.evaluate(shots: shots, subject: f(x: 0.4, dir: -1), rollDeg: 0, lockedTemplate: left);
    expect(actions(r2), [HintAction.panLeft]);
    expect(r2.hints.first.message, contains('시선 앞(왼쪽)'));
  });

  test('눈높이와 거리 안내', () {
    final r = engine.evaluate(shots: shots, subject: f(eye: 0.42, size: 0.22), rollDeg: 0, lockedTemplate: left);
    expect(actions(r), [HintAction.stepBack, HintAction.tiltDown]);
    final r2 = engine.evaluate(shots: shots, subject: f(eye: 0.2, size: 0.11), rollDeg: 0, lockedTemplate: left);
    expect(actions(r2), [HintAction.stepCloser, HintAction.tiltUp]);
  });

  test('관절·머리 잘림을 먼저 경고하고 점수를 깎는다', () {
    final r = engine.evaluate(shots: shots, subject: f(cut: 'left_knee'), rollDeg: 0);
    expect(r.hints.first.action, HintAction.jointCut);
    expect(r.hints.first.message, contains('무릎'));
    expect(r.ready, isFalse);
    expect(r.score, lessThan(80));
    final head = engine.evaluate(shots: shots, subject: f(top: -0.05), rollDeg: 0);
    expect(head.hints.first.message, contains('머리'));
  });

  test('수평 안내가 가장 먼저', () {
    final r = engine.evaluate(shots: shots, subject: f(), rollDeg: 5);
    expect(actions(r).first, HintAction.levelLeftUp);
    expect(engine.evaluate(shots: shots, subject: f(), rollDeg: -5).hints.first.action, HintAction.levelRightUp);
  });

  test('원하는 샷이 더 넓으면 뒤로, 좁으면 앞으로', () {
    final r = engine.evaluate(shots: shots, subject: f(), rollDeg: 0, targetShot: 'full_body');
    expect(actions(r), [HintAction.stepBack]);
    expect(r.hints.first.message, contains('전신으로'));
    expect(r.shot.id, 'full_body');
    final r2 = engine.evaluate(shots: shots, subject: f(shot: 'full_body', size: 0.075, eye: 0.24, x: 0.36), rollDeg: 0, targetShot: 'waist');
    expect(actions(r2), [HintAction.stepCloser]);
  });

  test('템플릿이 없는 샷은 가장 가까운 샷을 쓰고, 건물 배경이면 가운데 구도', () {
    final r = engine.evaluate(shots: shots, subject: f(shot: 'chest', size: 0.25), rollDeg: 0);
    expect(r.shot.id, 'waist');
    final c = engine.evaluate(shots: shots, subject: f(), rollDeg: 0, preferCentered: true);
    expect(c.template.id, 'waist-2');
  });

  test('인물이 없으면 찾기 안내', () {
    final r = engine.evaluate(shots: shots, subject: null, rollDeg: 0);
    expect(actions(r), [HintAction.findSubject]);
  });

  test('기본 assets/templates.json 은 다섯 가지 샷을 모두 담고 있다', () {
    final parsed = parseTemplates(File('assets/templates.json').readAsStringSync());
    expect(parsed.map((s) => s.id), shotTypes);
    for (final s in parsed) {
      expect(s.templates, isNotEmpty);
      expect(s.templates.first.tolSize, greaterThan(0));
    }
  });

  test('learner 출력 형식을 파싱하고, 예전 v1 형식은 거부', () {
    const json = '{"schema_version":2,"shots":[{"id":"waist","label":"반신","samples":30,"sources":{"coco":30},'
        '"templates":[{"id":"waist-1","description":"d","subject_cx":0.35,"eye_y":0.3,"head_size":0.15,'
        '"tol_x":0.05,"tol_eye":0.04,"tol_size":0.02,"turned_ratio":0.5,"support":30,"weight":30.0}]},'
        '{"id":"face","label":"얼굴","templates":[]}]}';
    final parsed = parseTemplates(json);
    expect(parsed, hasLength(1));
    expect(parsed.single.templates.single.eyeY, 0.3);
    expect(() => parseTemplates('{"schema_version":1,"scenes":[]}'), throwsFormatException);
  });
}
