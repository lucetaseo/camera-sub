import 'dart:io';

import 'package:camera_sub/composition/scene_classifier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final rules = SceneRules.fromJson(File('assets/scene_rules.json').readAsStringSync());

  test('라벨로 배경 장면을 고른다', () {
    final c = SceneClassifier(rules);
    expect(c.classifyOnce(const [SceneLabel('Beach', 0.9), SceneLabel('Sky', 0.8)]), 'beach');
    expect(c.classifyOnce(const [SceneLabel('Temple', 0.7), SceneLabel('Building', 0.6)]), 'architecture');
    expect(c.classifyOnce(const [SceneLabel('Mountain', 0.8)]), 'landscape');
    expect(c.classifyOnce(const [SceneLabel('Street', 0.8), SceneLabel('Car', 0.5)]), 'city');
    expect(rules.labels['beach'], '바다');
  });

  test('단어 단위로 비교해서 Skyscraper 를 sky 로 오인하지 않는다', () {
    final scores = SceneClassifier(rules).scoreLabels(const [SceneLabel('Skyscraper', 1.0)]);
    expect(scores['landscape'], isNull);
    expect(scores['city'], closeTo(0.6, 1e-9));
  });

  test('판단할 수 없으면 null', () {
    final c = SceneClassifier(rules);
    expect(c.update(const [SceneLabel('Sky', 0.6)]), isNull);
    expect(c.currentLabel, isNull);
  });

  test('장면은 연속으로 같은 결과가 나와야 바뀐다 (깜빡임 방지)', () {
    final c = SceneClassifier(rules, stableCount: 2);
    const beach = [SceneLabel('Beach', 0.9)];
    const city = [SceneLabel('Street', 0.9)];
    expect(c.update(beach), 'beach');
    expect(c.update(city), 'beach');
    expect(c.update(beach), 'beach');
    expect(c.update(city), 'beach');
    expect(c.update(city), 'city');
    expect(c.currentLabel, '도시');
  });
}
