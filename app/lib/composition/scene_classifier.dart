import 'dart:convert';

import 'guide_engine.dart';

/// 이미지 라벨 하나 (ML Kit 결과를 UI·플러그인과 분리하기 위한 값).
class SceneLabel {
  const SceneLabel(this.label, this.confidence);

  final String label;
  final double confidence;
}

/// assets/scene_rules.json: 라벨 단어 → 장면별 가중치.
class SceneRules {
  const SceneRules({
    required this.weights,
    this.minScore = 0.5,
    this.portraitSubjectH = 0.6,
    this.fallbackScene = 'landscape',
  });

  /// scene id → (라벨 단어 → 가중치)
  final Map<String, Map<String, double>> weights;
  final double minScore;
  final double portraitSubjectH;
  final String fallbackScene;

  factory SceneRules.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    if (j['schema_version'] != 1) {
      throw FormatException('지원하지 않는 scene_rules.json 버전: ${j['schema_version']}');
    }
    final scenes = j['scenes'] as Map<String, dynamic>;
    return SceneRules(
      weights: {
        for (final e in scenes.entries)
          e.key: {
            for (final w in (e.value as Map<String, dynamic>).entries) w.key.toLowerCase(): (w.value as num).toDouble(),
          },
      },
      minScore: (j['min_score'] as num?)?.toDouble() ?? 0.5,
      portraitSubjectH: (j['portrait_subject_h'] as num?)?.toDouble() ?? 0.6,
      fallbackScene: j['fallback_scene'] as String? ?? 'landscape',
    );
  }
}

/// 카메라 화면의 라벨과 인물 크기로 장면(바다/도시/건물 ...)을 고른다.
///
/// 장면이 프레임마다 바뀌면 안내가 흔들리므로, 같은 결과가 [stableCount]번
/// 연속으로 나와야 바꾼다.
class SceneClassifier {
  SceneClassifier(this.rules, {this.stableCount = 2, Set<String>? availableScenes})
      : availableScenes = availableScenes ?? rules.weights.keys.toSet();

  final SceneRules rules;
  final int stableCount;
  final Set<String> availableScenes;

  String? _current;
  String? _candidate;
  int _candidateHits = 0;

  String? get current => _current;

  /// 라벨 점수만으로 이번 프레임의 장면을 계산한다 (상태 변경 없음).
  String? classifyOnce(List<SceneLabel> labels, SubjectBox? subject) {
    if (subject != null && subject.height >= rules.portraitSubjectH && availableScenes.contains('portrait')) {
      return 'portrait';
    }
    final scores = scoreLabels(labels);
    String? best;
    var bestScore = rules.minScore;
    for (final e in scores.entries) {
      if (!availableScenes.contains(e.key)) continue;
      if (e.value >= bestScore) {
        best = e.key;
        bestScore = e.value;
      }
    }
    return best;
  }

  Map<String, double> scoreLabels(List<SceneLabel> labels) {
    final scores = <String, double>{};
    for (final l in labels) {
      // "Skyscraper" 가 "sky" 에 걸리지 않도록 단어 단위로 비교한다.
      final words = {l.label.toLowerCase(), ...l.label.toLowerCase().split(RegExp(r'[^a-z]+'))};
      for (final scene in rules.weights.entries) {
        var w = 0.0;
        for (final word in words) {
          final v = scene.value[word];
          if (v != null && v > w) w = v;
        }
        if (w > 0) scores[scene.key] = (scores[scene.key] ?? 0) + w * l.confidence;
      }
    }
    return scores;
  }

  /// 새 프레임 결과를 반영하고, 지금 확정된 장면을 돌려준다.
  String update(List<SceneLabel> labels, SubjectBox? subject) {
    final next = classifyOnce(labels, subject);
    if (next == null) {
      _candidate = null;
      _candidateHits = 0;
      return _current ??= _fallback();
    }
    if (next == _current) {
      _candidate = null;
      _candidateHits = 0;
      return next;
    }
    if (next == _candidate) {
      _candidateHits++;
    } else {
      _candidate = next;
      _candidateHits = 1;
    }
    if (_current == null || _candidateHits >= stableCount) {
      _current = next;
      _candidate = null;
      _candidateHits = 0;
    }
    return _current!;
  }

  String _fallback() =>
      availableScenes.contains(rules.fallbackScene) ? rules.fallbackScene : availableScenes.first;
}
