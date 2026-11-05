import 'dart:convert';

/// 구도 템플릿 하나 (learner/ 가 만든 templates.json 의 한 항목).
///
/// 좌표는 모두 0~1 로 정규화되어 있다. (0,0)=왼쪽 위.
class CompositionTemplate {
  const CompositionTemplate({
    required this.id,
    required this.description,
    required this.subjectCx,
    required this.subjectCy,
    required this.subjectH,
    this.tolX = 0.06,
    this.tolY = 0.06,
    this.tolH = 0.05,
    this.horizonY,
    this.headY,
    this.support = 0,
  });

  final String id;
  final String description;
  final double subjectCx;
  final double subjectCy;
  final double subjectH;
  final double tolX;
  final double tolY;
  final double tolH;
  final double? horizonY;
  final double? headY;
  final int support;

  factory CompositionTemplate.fromJson(Map<String, dynamic> j) {
    double d(String k, double fallback) => (j[k] as num?)?.toDouble() ?? fallback;
    return CompositionTemplate(
      id: j['id'] as String,
      description: j['description'] as String? ?? '',
      subjectCx: d('subject_cx', 0.5),
      subjectCy: d('subject_cy', 0.5),
      subjectH: d('subject_h', 0.4),
      tolX: d('tol_x', 0.06),
      tolY: d('tol_y', 0.06),
      tolH: d('tol_h', 0.05),
      horizonY: (j['horizon_y'] as num?)?.toDouble(),
      headY: (j['head_y'] as num?)?.toDouble(),
      support: (j['support'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 장면(바다, 도시 ...)과 그 장면에서 잘 쓰이는 구도 템플릿 목록.
class Scene {
  const Scene({required this.id, required this.label, required this.templates});

  final String id;
  final String label;
  final List<CompositionTemplate> templates;

  factory Scene.fromJson(Map<String, dynamic> j) => Scene(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        templates: (j['templates'] as List)
            .map((t) => CompositionTemplate.fromJson(t as Map<String, dynamic>))
            .toList(),
      );
}

const supportedSchemaVersion = 1;

List<Scene> parseTemplates(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final version = json['schema_version'];
  if (version != supportedSchemaVersion) {
    throw FormatException('지원하지 않는 templates.json 버전: $version');
  }
  return (json['scenes'] as List)
      .map((s) => Scene.fromJson(s as Map<String, dynamic>))
      .where((s) => s.templates.isNotEmpty)
      .toList();
}
