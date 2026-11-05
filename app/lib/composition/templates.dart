import 'dart:convert';

/// 인물 구도 템플릿 (learner/ 가 만든 templates.json v2 의 한 항목).
///
/// 오른쪽을 보는 인물 기준이다. 인물이 왼쪽을 보면 [subjectCx] 를 좌우 반전해서 쓴다.
class ShotTemplate {
  const ShotTemplate({
    required this.id,
    required this.description,
    required this.subjectCx,
    required this.eyeY,
    required this.headSize,
    this.tolX = 0.06,
    this.tolEye = 0.045,
    this.tolSize = 0.02,
    this.support = 0,
  });

  final String id;
  final String description;

  /// 얼굴 중심 x
  final double subjectCx;

  /// 눈높이 y
  final double eyeY;

  /// 눈~어깨 거리 (화면 높이 대비)
  final double headSize;
  final double tolX;
  final double tolEye;
  final double tolSize;
  final int support;

  double targetX(int faceDir) => faceDir < 0 ? 1 - subjectCx : subjectCx;

  factory ShotTemplate.fromJson(Map<String, dynamic> j) {
    double d(String k, double fallback) => (j[k] as num?)?.toDouble() ?? fallback;
    final headSize = d('head_size', 0.15);
    return ShotTemplate(
      id: j['id'] as String,
      description: j['description'] as String? ?? '',
      subjectCx: d('subject_cx', 0.5),
      eyeY: d('eye_y', 0.33),
      headSize: headSize,
      tolX: d('tol_x', 0.06),
      tolEye: d('tol_eye', 0.045),
      tolSize: d('tol_size', headSize * 0.15),
      support: (j['support'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 샷 종류(전신/무릎샷/반신/상반신/얼굴)와 그 샷의 구도 템플릿들.
class Shot {
  const Shot({required this.id, required this.label, required this.templates, this.samples = 0});

  final String id;
  final String label;
  final int samples;
  final List<ShotTemplate> templates;

  factory Shot.fromJson(Map<String, dynamic> j) => Shot(
        id: j['id'] as String,
        label: j['label'] as String? ?? j['id'] as String,
        samples: (j['samples'] as num?)?.toInt() ?? 0,
        templates: (j['templates'] as List)
            .map((t) => ShotTemplate.fromJson(t as Map<String, dynamic>))
            .toList(),
      );
}

const supportedSchemaVersion = 2;

List<Shot> parseTemplates(String source) {
  final json = jsonDecode(source) as Map<String, dynamic>;
  final version = json['schema_version'];
  if (version != supportedSchemaVersion) {
    throw FormatException('지원하지 않는 templates.json 버전: $version');
  }
  return (json['shots'] as List)
      .map((s) => Shot.fromJson(s as Map<String, dynamic>))
      .where((s) => s.templates.isNotEmpty)
      .toList();
}
