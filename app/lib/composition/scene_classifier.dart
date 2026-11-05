import 'dart:convert';

/// 이미지 라벨 하나 (ML Kit 결과를 플러그인과 분리하기 위한 값).
class SceneLabel {
  const SceneLabel(this.label, this.confidence);

  final String label;
  final double confidence;
}

/// assets/scene_rules.json: 라벨 단어 → 배경 장면 가중치.
class SceneRules {
  const SceneRules({required this.weights, required this.labels, this.minScore = 0.5});

  /// scene id → (라벨 단어 → 가중치)
  final Map<String, Map<String, double>> weights;

  /// scene id → 한국어 이름
  final Map<String, String> labels;
  final double minScore;

  factory SceneRules.fromJson(String source) {
    final j = jsonDecode(source) as Map<String, dynamic>;
    if (j['schema_version'] != 2) {
      throw FormatException('지원하지 않는 scene_rules.json 버전: ${j['schema_version']}');
    }
    final scenes = (j['scenes'] as Map<String, dynamic>).cast<String, Map<String, dynamic>>();
    return SceneRules(
      weights: {
        for (final e in scenes.entries)
          e.key: {
            for (final w in (e.value['words'] as Map<String, dynamic>).entries)
              w.key.toLowerCase(): (w.value as num).toDouble(),
          },
      },
      labels: {for (final e in scenes.entries) e.key: e.value['label'] as String? ?? e.key},
      minScore: (j['min_score'] as num?)?.toDouble() ?? 0.5,
    );
  }
}

/// 카메라 화면의 라벨로 배경 장면(바다/풍경/도시/건물)을 고른다.
///
/// 장면이 프레임마다 바뀌면 안내가 흔들리므로, 같은 결과가 [stableCount]번
/// 연속으로 나와야 바꾼다. 판단할 수 없으면 null.
class SceneClassifier {
  SceneClassifier(this.rules, {this.stableCount = 2});

  final SceneRules rules;
  final int stableCount;

  String? _current;
  String? _candidate;
  int _hits = 0;

  String? get current => _current;
  String? get currentLabel => _current == null ? null : rules.labels[_current];

  Map<String, double> scoreLabels(List<SceneLabel> labels) {
    final scores = <String, double>{};
    for (final l in labels) {
      // "Skyscraper" 가 "sky" 에 걸리지 않도록 단어 단위로 비교한다.
      final lower = l.label.toLowerCase();
      final words = {lower, ...lower.split(RegExp(r'[^a-z]+'))};
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

  String? classifyOnce(List<SceneLabel> labels) {
    String? best;
    var bestScore = rules.minScore;
    for (final e in scoreLabels(labels).entries) {
      if (e.value >= bestScore) {
        best = e.key;
        bestScore = e.value;
      }
    }
    return best;
  }

  /// 새 프레임 결과를 반영하고, 확정된 장면을 돌려준다.
  String? update(List<SceneLabel> labels) {
    final next = classifyOnce(labels);
    if (next == _current) {
      _candidate = null;
      _hits = 0;
      return _current;
    }
    if (next == _candidate) {
      _hits++;
    } else {
      _candidate = next;
      _hits = 1;
    }
    if (_hits >= stableCount || (_current == null && next != null)) {
      _current = next;
      _candidate = null;
      _hits = 0;
    }
    return _current;
  }
}
