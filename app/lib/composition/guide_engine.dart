import 'dart:math' as math;

import 'templates.dart';

/// 화면 속 인물 박스 (0~1 정규화, 세로 화면 기준).
class SubjectBox {
  const SubjectBox(this.left, this.top, this.right, this.bottom);

  final double left;
  final double top;
  final double right;
  final double bottom;

  double get cx => (left + right) / 2;
  double get cy => (top + bottom) / 2;
  double get height => bottom - top;
  double get width => right - left;

  SubjectBox lerp(SubjectBox o, double t) => SubjectBox(
        left + (o.left - left) * t,
        top + (o.top - top) * t,
        right + (o.right - right) * t,
        bottom + (o.bottom - bottom) * t,
      );
}

/// 화면에 보여줄 화살표 방향.
enum HintAction { levelLeftUp, levelRightUp, panLeft, panRight, tiltUp, tiltDown, stepBack, stepCloser, findSubject, ready }

class Hint {
  const Hint(this.action, this.message);

  final HintAction action;
  final String message;

  @override
  String toString() => message;
}

class GuideResult {
  const GuideResult({required this.template, required this.score, required this.hints, required this.ready});

  /// 지금 화면과 비교한 목표 구도 (인물이 없으면 장면의 첫 번째 템플릿).
  final CompositionTemplate template;

  /// 0~100 구도 점수.
  final int score;

  /// 중요한 순서대로 정렬된 안내.
  final List<Hint> hints;

  /// 지금 찍으면 좋은 상태인지.
  final bool ready;
}

/// 구도 규칙을 적용해 촬영자에게 줄 안내를 계산한다. (UI 와 분리된 순수 로직)
class GuideEngine {
  const GuideEngine({this.levelToleranceDeg = 2.0});

  final double levelToleranceDeg;

  /// [lockedTemplate] 이 있으면 그 구도로, 없으면 지금 화면과 가장 가까운 구도로 안내한다.
  GuideResult evaluate({
    required Scene scene,
    required SubjectBox? subject,
    required double rollDeg,
    CompositionTemplate? lockedTemplate,
  }) {
    final hints = <Hint>[];

    // 1) 수평 (가장 먼저 맞춰야 나머지 판단이 정확하다)
    final tilt = rollDeg.abs();
    if (tilt > levelToleranceDeg) {
      final deg = tilt.toStringAsFixed(0);
      // 가속도계 x>0 이면 휴대폰 왼쪽이 내려간 상태
      hints.add(rollDeg > 0
          ? Hint(HintAction.levelLeftUp, '수평이 $deg° 기울었어요 · 왼쪽을 살짝 올리세요')
          : Hint(HintAction.levelRightUp, '수평이 $deg° 기울었어요 · 오른쪽을 살짝 올리세요'));
    }
    final tiltPenalty = math.max(0.0, tilt - 1.0) * 4;

    if (subject == null) {
      final template = lockedTemplate ?? scene.templates.first;
      hints.add(const Hint(HintAction.findSubject, '인물을 화면에 담아주세요'));
      return GuideResult(
        template: template,
        score: _clampScore(60 - tiltPenalty),
        hints: hints,
        ready: false,
      );
    }

    final template = lockedTemplate ?? closestTemplate(scene, subject);
    final d = distance(template, subject);

    // 2) 잘림 방지
    if (subject.top < 0.02) {
      hints.add(const Hint(HintAction.stepBack, '머리가 잘려요 · 한 걸음 뒤로 가거나 카메라를 위로'));
    } else if (subject.height < 0.8 && subject.bottom > 0.98) {
      hints.add(const Hint(HintAction.tiltDown, '발끝이 잘려요 · 카메라를 살짝 아래로'));
    }

    // 3) 크기 → 위치 순서로 (거리를 바꾸면 위치도 같이 바뀌므로)
    final dh = subject.height - template.subjectH;
    if (dh > template.tolH) {
      hints.add(const Hint(HintAction.stepBack, '인물이 커요 · 한 걸음 뒤로 (또는 줌 아웃)'));
    } else if (dh < -template.tolH) {
      hints.add(const Hint(HintAction.stepCloser, '인물이 작아요 · 한 걸음 앞으로 (또는 줌 인)'));
    }

    // 카메라를 오른쪽으로 돌리면 화면 속 인물은 왼쪽으로 움직인다.
    final dx = subject.cx - template.subjectCx;
    if (dx > template.tolX) {
      hints.add(const Hint(HintAction.panRight, '카메라를 오른쪽으로 조금 돌리세요'));
    } else if (dx < -template.tolX) {
      hints.add(const Hint(HintAction.panLeft, '카메라를 왼쪽으로 조금 돌리세요'));
    }

    // 카메라를 아래로 숙이면 화면 속 인물은 위로 움직인다.
    final dy = subject.cy - template.subjectCy;
    if (dy > template.tolY) {
      hints.add(const Hint(HintAction.tiltDown, '카메라를 살짝 아래로 숙이세요'));
    } else if (dy < -template.tolY) {
      hints.add(const Hint(HintAction.tiltUp, '카메라를 살짝 위로 드세요'));
    }

    final ready = hints.isEmpty;
    if (ready) hints.add(const Hint(HintAction.ready, '좋아요! 지금 찍으세요'));

    return GuideResult(
      template: template,
      score: _clampScore(100 - d * 15 - tiltPenalty),
      hints: hints,
      ready: ready,
    );
  }

  /// 허용 오차로 나눈 거리. 1 이하이면 해당 구도 범위 안이다.
  static double distance(CompositionTemplate t, SubjectBox s) {
    final x = (s.cx - t.subjectCx) / t.tolX;
    final y = (s.cy - t.subjectCy) / t.tolY;
    final h = (s.height - t.subjectH) / t.tolH;
    return math.sqrt(x * x + y * y + h * h) / math.sqrt(3);
  }

  static CompositionTemplate closestTemplate(Scene scene, SubjectBox s) {
    var best = scene.templates.first;
    var bestD = double.infinity;
    for (final t in scene.templates) {
      final d = distance(t, s);
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
    return best;
  }

  static int _clampScore(double v) => v.clamp(0, 100).round();
}

/// 프레임마다 흔들리는 검출 결과를 부드럽게 만든다.
class SubjectSmoother {
  SubjectSmoother({this.alpha = 0.35, this.maxMissedFrames = 6});

  final double alpha;
  final int maxMissedFrames;
  SubjectBox? _value;
  int _missed = 0;

  SubjectBox? get value => _value;

  SubjectBox? update(SubjectBox? next) {
    if (next == null) {
      if (++_missed > maxMissedFrames) _value = null;
      return _value;
    }
    _missed = 0;
    _value = _value == null ? next : _value!.lerp(next, alpha);
    return _value;
  }
}
