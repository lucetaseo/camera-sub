/// 인물 구도 특징. learner/composition_learner/portrait.py 와 같은 계산이다.
/// 바꿀 때는 둘을 함께 바꾸고 shared/portrait_fixtures.json 테스트를 돌릴 것.
library;

/// COCO 17개 관절 이름 (ML Kit 33개 랜드마크도 이 이름으로 바꿔 쓴다).
const keypointNames = [
  'nose', 'left_eye', 'right_eye', 'left_ear', 'right_ear',
  'left_shoulder', 'right_shoulder', 'left_elbow', 'right_elbow', 'left_wrist', 'right_wrist',
  'left_hip', 'right_hip', 'left_knee', 'right_knee', 'left_ankle', 'right_ankle',
]; // dart format off

/// 넓은 샷 → 가까운 샷 순서.
const shotTypes = ['full_body', 'knee', 'waist', 'chest', 'face'];
const shotLabels = {'full_body': '전신', 'knee': '무릎샷', 'waist': '반신', 'chest': '상반신', 'face': '얼굴 클로즈업'};

const cutJoints = [
  'left_knee', 'right_knee', 'left_ankle', 'right_ankle',
  'left_wrist', 'right_wrist', 'left_elbow', 'right_elbow',
]; // dart format off
const cutMargin = 0.035;
const faceTurnThreshold = 0.12;

const jointLabels = {
  'left_knee': '무릎', 'right_knee': '무릎', 'left_ankle': '발목', 'right_ankle': '발목',
  'left_wrist': '손목', 'right_wrist': '손목', 'left_elbow': '팔꿈치', 'right_elbow': '팔꿈치',
}; // dart format off

/// 관절 하나 (0~1 정규화, 화면 밖 추정값은 범위를 벗어날 수 있음).
class Kp {
  const Kp(this.x, this.y, this.visible);

  final double x;
  final double y;
  final bool visible;

  Kp lerp(Kp o, double t) => Kp(x + (o.x - x) * t, y + (o.y - y) * t, o.visible);
}

class PortraitFeatures {
  const PortraitFeatures({
    required this.shot,
    required this.headX,
    required this.eyeY,
    required this.headSize,
    required this.topY,
    required this.faceDir,
    required this.jointCut,
  });

  final String shot;
  final double headX;
  final double eyeY;

  /// 눈~어깨 세로 거리 (화면 높이 대비). 클수록 가까이 찍은 것.
  final double headSize;

  /// 머리 꼭대기 추정 y. 0 보다 작으면 머리가 잘림.
  final double topY;

  /// -1: 화면 왼쪽을 봄, 0: 정면, 1: 화면 오른쪽을 봄.
  final int faceDir;

  /// 화면 아래 끝에서 잘린 관절.
  final String? jointCut;

  double get canonicalX => faceDir < 0 ? 1 - headX : headX;
}

bool _inFrame(Kp? p, [double margin = 0.01]) =>
    p != null && p.visible && p.x >= -margin && p.x <= 1 + margin && p.y >= -margin && p.y <= 1 + margin;

double? _mean(Iterable<double> v) => v.isEmpty ? null : v.reduce((a, b) => a + b) / v.length;

PortraitFeatures? computeFeatures(Map<String, Kp> kps) {
  Kp? g(String n) => kps[n];
  bool seen(String n) => _inFrame(g(n));

  final eyes = [for (final n in ['left_eye', 'right_eye']) if (seen(n)) g(n)!];
  final headPts = [...eyes, if (seen('nose')) g('nose')!];
  if (headPts.isEmpty) return null;
  final eyeY = eyes.isNotEmpty ? _mean(eyes.map((p) => p.y))! : g('nose')!.y;
  final headX = _mean(headPts.map((p) => p.x))!;

  final shoulders = [
    for (final n in ['left_shoulder', 'right_shoulder'])
      if (g(n) != null && g(n)!.visible) g(n)!
  ];
  double? headSize;
  if (shoulders.isNotEmpty) headSize = _mean(shoulders.map((p) => p.y))! - eyeY;
  if (headSize == null || headSize <= 0.01) {
    final ears = [for (final n in ['left_ear', 'right_ear']) if (seen(n)) g(n)!];
    final span = ears.length == 2 ? ears : eyes;
    if (span.length == 2) headSize = (span[0].x - span[1].x).abs() * 1.6;
  }
  if (headSize == null || headSize <= 0.01) return null;

  bool anySeen(List<String> names) => names.any(seen);
  final String shot;
  if (anySeen(['left_ankle', 'right_ankle'])) {
    shot = 'full_body';
  } else if (anySeen(['left_knee', 'right_knee'])) {
    shot = 'knee';
  } else if (anySeen(['left_hip', 'right_hip'])) {
    shot = 'waist';
  } else if (anySeen(['left_shoulder', 'right_shoulder'])) {
    shot = 'chest';
  } else {
    shot = 'face';
  }

  var faceDir = 0;
  if (seen('nose')) {
    final nose = g('nose')!;
    final ears = [for (final n in ['left_ear', 'right_ear']) if (seen(n)) g(n)!];
    if (ears.length == 1) {
      faceDir = nose.x > ears[0].x ? 1 : -1;
    } else {
      final ref = ears.length == 2 ? ears : eyes;
      if (ref.length == 2) {
        final width = [(ref[0].x - ref[1].x).abs(), headSize * 0.3].reduce((a, b) => a > b ? a : b);
        final off = (nose.x - (ref[0].x + ref[1].x) / 2) / width;
        faceDir = off > faceTurnThreshold ? 1 : (off < -faceTurnThreshold ? -1 : 0);
      }
    }
  }

  String? jointCut;
  for (final n in cutJoints) {
    final p = g(n);
    if (p != null && p.visible && p.x >= 0 && p.x <= 1 && (p.y - 1.0).abs() < cutMargin) {
      jointCut = n;
      break;
    }
  }

  return PortraitFeatures(
    shot: shot,
    headX: headX,
    eyeY: eyeY,
    headSize: headSize,
    topY: eyeY - headSize * 0.55,
    faceDir: faceDir,
    jointCut: jointCut,
  );
}

/// 프레임마다 흔들리는 관절 위치를 부드럽게 만든다.
class KeypointSmoother {
  KeypointSmoother({this.alpha = 0.4, this.maxMissedFrames = 6});

  final double alpha;
  final int maxMissedFrames;
  Map<String, Kp>? _value;
  int _missed = 0;

  Map<String, Kp>? update(Map<String, Kp>? next) {
    if (next == null) {
      if (++_missed > maxMissedFrames) _value = null;
      return _value;
    }
    _missed = 0;
    final prev = _value;
    _value = prev == null
        ? Map.of(next)
        : {for (final e in next.entries) e.key: prev[e.key]?.lerp(e.value, alpha) ?? e.value};
    return _value;
  }
}
