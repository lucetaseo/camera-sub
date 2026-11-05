import 'dart:io';

import 'package:camera_sub/composition/guide_engine.dart';
import 'package:camera_sub/composition/templates.dart';
import 'package:flutter_test/flutter_test.dart';

const left = CompositionTemplate(
  id: 'l', description: '왼쪽', subjectCx: 0.333, subjectCy: 0.6, subjectH: 0.4, tolX: 0.05, tolY: 0.05, tolH: 0.05);
const right = CompositionTemplate(
  id: 'r', description: '오른쪽', subjectCx: 0.667, subjectCy: 0.6, subjectH: 0.4, tolX: 0.05, tolY: 0.05, tolH: 0.05);
const scene = Scene(id: 's', label: '테스트', templates: [left, right]);

SubjectBox box(double cx, double cy, double h, {double w = 0.15}) =>
    SubjectBox(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2);

void main() {
  const engine = GuideEngine();
  List<HintAction> actions(GuideResult r) => r.hints.map((h) => h.action).toList();

  test('목표 구도 안 + 수평이면 촬영 준비 완료', () {
    final r = engine.evaluate(scene: scene, subject: box(0.34, 0.6, 0.41), rollDeg: 0.5);
    expect(r.ready, isTrue);
    expect(r.template.id, 'l');
    expect(actions(r), [HintAction.ready]);
    expect(r.score, greaterThan(90));
  });

  test('가장 가까운 템플릿을 자동 선택', () {
    final r = engine.evaluate(scene: scene, subject: box(0.6, 0.6, 0.4), rollDeg: 0);
    expect(r.template.id, 'r');
  });

  test('고정한 템플릿 기준으로 방향 안내: 인물이 너무 오른쪽이면 카메라를 오른쪽으로', () {
    final r = engine.evaluate(scene: scene, subject: box(0.6, 0.6, 0.4), rollDeg: 0, lockedTemplate: left);
    expect(r.ready, isFalse);
    expect(actions(r), [HintAction.panRight]);
  });

  test('인물이 아래쪽이면 카메라를 아래로, 너무 크면 뒤로', () {
    final r = engine.evaluate(scene: scene, subject: box(0.333, 0.7, 0.55), rollDeg: 0, lockedTemplate: left);
    expect(actions(r), [HintAction.stepBack, HintAction.tiltDown]);
  });

  test('수평 안내가 가장 먼저, 방향도 맞게', () {
    final r = engine.evaluate(scene: scene, subject: box(0.333, 0.6, 0.4), rollDeg: 5);
    expect(actions(r).first, HintAction.levelLeftUp);
    expect(r.ready, isFalse);
    final r2 = engine.evaluate(scene: scene, subject: box(0.333, 0.6, 0.4), rollDeg: -5);
    expect(actions(r2).first, HintAction.levelRightUp);
  });

  test('머리/발 잘림 경고', () {
    final head = engine.evaluate(scene: scene, subject: const SubjectBox(0.3, 0.0, 0.4, 0.5), rollDeg: 0);
    expect(head.hints.first.message, contains('머리'));
    final feet = engine.evaluate(scene: scene, subject: const SubjectBox(0.3, 0.6, 0.4, 0.99), rollDeg: 0);
    expect(feet.hints.first.message, contains('발끝'));
  });

  test('인물이 없으면 찾기 안내', () {
    final r = engine.evaluate(scene: scene, subject: null, rollDeg: 0);
    expect(actions(r), [HintAction.findSubject]);
    expect(r.ready, isFalse);
  });

  test('smoother 는 잠깐 놓친 프레임을 유지하고 오래 놓치면 지운다', () {
    final s = SubjectSmoother(alpha: 0.5, maxMissedFrames: 2);
    s.update(box(0.2, 0.5, 0.4));
    final v = s.update(box(0.4, 0.5, 0.4))!;
    expect(v.cx, closeTo(0.3, 1e-9));
    expect(s.update(null), isNotNull);
    expect(s.update(null), isNotNull);
    expect(s.update(null), isNull);
  });

  test('기본 assets/templates.json 이 파싱된다', () {
    final scenes = parseTemplates(File('assets/templates.json').readAsStringSync());
    expect(scenes.map((s) => s.id), containsAll(['landscape', 'beach', 'city', 'architecture', 'portrait']));
    expect(scenes.first.templates.first.horizonY, closeTo(0.667, 1e-9));
  });

  test('learner 가 만든 JSON(null horizon 포함)도 파싱되고, 잘못된 버전은 거부', () {
    const json = '{"schema_version":1,"scenes":[{"id":"x","label":"X","samples":3,"templates":'
        '[{"id":"x-1","description":"d","subject_cx":0.3,"subject_cy":0.6,"subject_h":0.2,'
        '"tol_x":0.05,"tol_y":0.05,"tol_h":0.04,"horizon_y":null,"head_y":0.5,"support":3}]},'
        '{"id":"empty","label":"E","samples":0,"templates":[]}]}';
    final scenes = parseTemplates(json);
    expect(scenes, hasLength(1));
    expect(scenes.single.templates.single.horizonY, isNull);
    expect(() => parseTemplates('{"schema_version":2,"scenes":[]}'), throwsFormatException);
  });
}
