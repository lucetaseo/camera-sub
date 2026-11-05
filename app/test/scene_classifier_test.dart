import 'dart:io';

import 'package:camera_sub/composition/guide_engine.dart';
import 'package:camera_sub/composition/scene_classifier.dart';
import 'package:camera_sub/composition/templates.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final rules = SceneRules.fromJson(File('assets/scene_rules.json').readAsStringSync());
  const small = SubjectBox(0.3, 0.6, 0.4, 0.8);
  const big = SubjectBox(0.2, 0.15, 0.6, 0.95);

  test('scene_rules.json 의 장면이 templates.json 에 모두 있다', () {
    final scenes = parseTemplates(File('assets/templates.json').readAsStringSync()).map((s) => s.id).toSet();
    expect(scenes, containsAll(rules.weights.keys));
    expect(scenes, contains(rules.fallbackScene));
  });

  test('라벨로 장면을 고른다', () {
    final c = SceneClassifier(rules);
    expect(c.classifyOnce(const [SceneLabel('Beach', 0.9), SceneLabel('Sky', 0.8)], small), 'beach');
    expect(c.classifyOnce(const [SceneLabel('Temple', 0.7), SceneLabel('Building', 0.6)], small), 'architecture');
    expect(c.classifyOnce(const [SceneLabel('Mountain', 0.8)], null), 'landscape');
    expect(c.classifyOnce(const [SceneLabel('Street', 0.8), SceneLabel('Car', 0.5)], small), 'city');
  });

  test('인물이 화면을 크게 차지하면 인물 클로즈업', () {
    final c = SceneClassifier(rules);
    expect(c.classifyOnce(const [SceneLabel('Beach', 0.9)], big), 'portrait');
  });

  test('단어 단위로 비교해서 Skyscraper 를 sky 로 오인하지 않는다', () {
    final c = SceneClassifier(rules);
    final scores = c.scoreLabels(const [SceneLabel('Skyscraper', 1.0)]);
    expect(scores['landscape'], isNull);
    expect(scores['city'], closeTo(0.6, 1e-9));
  });

  test('점수가 낮으면 판단하지 않고, 처음엔 기본 장면', () {
    final c = SceneClassifier(rules);
    expect(c.classifyOnce(const [SceneLabel('Sky', 0.6)], null), isNull);
    expect(c.update(const [SceneLabel('Sky', 0.6)], null), 'landscape');
  });

  test('장면은 연속으로 같은 결과가 나와야 바뀐다 (깜빡임 방지)', () {
    final c = SceneClassifier(rules, stableCount: 2);
    const beach = [SceneLabel('Beach', 0.9)];
    const city = [SceneLabel('Street', 0.9)];
    expect(c.update(beach, small), 'beach'); // 첫 결과는 바로 반영
    expect(c.update(city, small), 'beach'); // 한 번은 무시
    expect(c.update(beach, small), 'beach');
    expect(c.update(city, small), 'beach');
    expect(c.update(city, small), 'city'); // 두 번 연속이면 변경
  });

  test('템플릿이 없는 장면은 고르지 않는다', () {
    final c = SceneClassifier(rules, availableScenes: {'landscape', 'city'});
    expect(c.classifyOnce(const [SceneLabel('Beach', 0.9)], big), isNull);
    expect(c.update(const [SceneLabel('Beach', 0.9)], big), 'landscape');
  });
}
