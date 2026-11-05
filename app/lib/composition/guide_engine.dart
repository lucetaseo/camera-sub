import 'dart:math' as math;

import 'portrait.dart';
import 'templates.dart';

/// 화면에 보여줄 안내 종류 (아이콘 선택용).
enum HintAction {
  levelLeftUp,
  levelRightUp,
  panLeft,
  panRight,
  tiltUp,
  tiltDown,
  stepBack,
  stepCloser,
  jointCut,
  findSubject,
  ready,
}

class Hint {
  const Hint(this.action, this.message);

  final HintAction action;
  final String message;

  @override
  String toString() => message;
}

class GuideResult {
  const GuideResult({
    required this.shot,
    required this.template,
    required this.targetX,
    required this.score,
    required this.hints,
    required this.ready,
    this.observedShot,
  });

  /// 안내 기준 샷 (사용자가 고른 샷 또는 지금 화면의 샷).
  final Shot shot;

  /// 지금 화면에서 판단한 샷 (인물이 없으면 null).
  final String? observedShot;

  final ShotTemplate template;

  /// 인물의 시선 방향까지 반영한 목표 얼굴 x.
  final double targetX;

  final int score;

  /// 중요한 순서대로.
  final List<Hint> hints;
  final bool ready;
}

/// 인물 구도 규칙을 적용해 촬영자에게 줄 안내를 계산한다 (UI 와 분리된 순수 로직).
class GuideEngine {
  const GuideEngine({this.levelToleranceDeg = 2.0});

  final double levelToleranceDeg;

  /// [targetShot] 이 null 이면 지금 화면의 샷으로 안내한다.
  /// [preferCentered] 는 건물·대칭 배경처럼 가운데 구도가 어울릴 때 true.
  GuideResult evaluate({
    required List<Shot> shots,
    required PortraitFeatures? subject,
    required double rollDeg,
    String? targetShot,
    ShotTemplate? lockedTemplate,
    bool preferCentered = false,
  }) {
    final hints = <Hint>[];
    final tilt = rollDeg.abs();
    if (tilt > levelToleranceDeg) {
      final deg = tilt.toStringAsFixed(0);
      // 가속도계 x>0 이면 휴대폰 왼쪽이 내려간 상태
      hints.add(rollDeg > 0
          ? Hint(HintAction.levelLeftUp, '수평이 $deg° 기울었어요 · 왼쪽을 살짝 올리세요')
          : Hint(HintAction.levelRightUp, '수평이 $deg° 기울었어요 · 오른쪽을 살짝 올리세요'));
    }
    final tiltPenalty = math.max(0.0, tilt - 1.0) * 4;

    final shot = _shotFor(shots, targetShot ?? subject?.shot ?? 'waist');
    final faceDir = subject?.faceDir ?? 0;

    if (subject == null) {
      final t = lockedTemplate ?? shot.templates.first;
      hints.add(const Hint(HintAction.findSubject, '인물을 화면에 담아주세요'));
      return GuideResult(
        shot: shot,
        template: t,
        targetX: t.subjectCx,
        score: _clamp(50 - tiltPenalty),
        hints: hints,
        ready: false,
      );
    }

    // 원하는 샷과 지금 샷이 다르면 거리부터 맞춘다.
    if (targetShot != null && subject.shot != targetShot) {
      final wider = shotTypes.indexOf(targetShot) < shotTypes.indexOf(subject.shot);
      final label = shotLabels[targetShot] ?? targetShot;
      hints.add(wider
          ? Hint(HintAction.stepBack, '$label으로 찍으려면 뒤로 물러나세요 (또는 줌 아웃)')
          : Hint(HintAction.stepCloser, '$label으로 찍으려면 앞으로 다가가세요 (또는 줌 인)'));
      final t = lockedTemplate ?? shot.templates.first;
      return GuideResult(
        shot: shot,
        observedShot: subject.shot,
        template: t,
        targetX: t.targetX(faceDir, subject.headX),
        score: _clamp(40 - tiltPenalty),
        hints: hints,
        ready: false,
      );
    }

    final t = lockedTemplate ?? (preferCentered ? _mostCentered(shot) : closestTemplate(shot, subject));
    final targetX = t.targetX(faceDir, subject.headX);

    // 잘림
    var cutPenalty = 0.0;
    if (subject.jointCut != null) {
      cutPenalty = 25;
      final joint = jointLabels[subject.jointCut] ?? '관절';
      hints.add(Hint(
        HintAction.jointCut,
        joint == '무릎' || joint == '발목'
            ? '$joint에서 잘려요 · 조금 더 아래까지 담거나 그보다 위에서 자르세요'
            : '$joint에서 잘려요 · 프레임을 살짝 옮기세요',
      ));
    }
    if (subject.topY < -0.01 && subject.shot != 'face') {
      cutPenalty += 15;
      hints.add(const Hint(HintAction.tiltUp, '머리가 잘려요 · 카메라를 살짝 위로'));
    }

    // 거리(얼굴 크기) → 좌우(시선 앞 여백) → 눈높이 순서
    final ds = subject.headSize - t.headSize;
    if (ds > t.tolSize) {
      hints.add(const Hint(HintAction.stepBack, '인물이 커요 · 반 걸음 뒤로 (또는 줌 아웃)'));
    } else if (ds < -t.tolSize) {
      hints.add(const Hint(HintAction.stepCloser, '인물이 작아요 · 반 걸음 앞으로 (또는 줌 인)'));
    }

    // 카메라를 오른쪽으로 돌리면 화면 속 인물은 왼쪽으로 움직인다.
    final dx = subject.headX - targetX;
    if (dx > t.tolX) {
      hints.add(Hint(
        HintAction.panRight,
        faceDir > 0 ? '시선 앞(오른쪽)에 여백을 두세요 · 카메라를 오른쪽으로 조금' : '카메라를 오른쪽으로 조금 돌리세요',
      ));
    } else if (dx < -t.tolX) {
      hints.add(Hint(
        HintAction.panLeft,
        faceDir < 0 ? '시선 앞(왼쪽)에 여백을 두세요 · 카메라를 왼쪽으로 조금' : '카메라를 왼쪽으로 조금 돌리세요',
      ));
    }

    // 카메라를 아래로 숙이면 화면 속 인물은 위로 움직인다.
    final dy = subject.eyeY - t.eyeY;
    if (dy > t.tolEye) {
      hints.add(const Hint(HintAction.tiltDown, '눈높이가 낮아요 · 카메라를 살짝 아래로'));
    } else if (dy < -t.tolEye) {
      hints.add(const Hint(HintAction.tiltUp, '눈높이가 높아요 · 카메라를 살짝 위로'));
    }

    final ready = hints.isEmpty;
    if (ready) hints.add(const Hint(HintAction.ready, '좋아요! 지금 찍으세요'));

    return GuideResult(
      shot: shot,
      observedShot: subject.shot,
      template: t,
      targetX: targetX,
      score: _clamp(100 - distance(t, subject) * 15 - tiltPenalty - cutPenalty),
      hints: hints,
      ready: ready,
    );
  }

  /// 허용 오차로 나눈 거리. 1 이하면 템플릿 범위 안.
  static double distance(ShotTemplate t, PortraitFeatures s) {
    final x = (s.headX - t.targetX(s.faceDir, s.headX)) / t.tolX;
    final y = (s.eyeY - t.eyeY) / t.tolEye;
    final h = (s.headSize - t.headSize) / t.tolSize;
    return math.sqrt(x * x + y * y + h * h) / math.sqrt(3);
  }

  static ShotTemplate closestTemplate(Shot shot, PortraitFeatures s) {
    var best = shot.templates.first;
    var bestD = double.infinity;
    for (final t in shot.templates) {
      final d = distance(t, s);
      if (d < bestD) {
        bestD = d;
        best = t;
      }
    }
    return best;
  }

  static ShotTemplate _mostCentered(Shot shot) =>
      shot.templates.reduce((a, b) => (a.subjectCx - 0.5).abs() <= (b.subjectCx - 0.5).abs() ? a : b);

  /// 템플릿이 없는 샷이면 가장 가까운 샷을 쓴다.
  static Shot _shotFor(List<Shot> shots, String id) {
    for (final s in shots) {
      if (s.id == id) return s;
    }
    final want = shotTypes.indexOf(id);
    return shots.reduce((a, b) =>
        (shotTypes.indexOf(a.id) - want).abs() <= (shotTypes.indexOf(b.id) - want).abs() ? a : b);
  }

  static int _clamp(double v) => v.clamp(0, 100).round();
}
