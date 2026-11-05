import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../composition/guide_engine.dart';
import '../composition/portrait.dart';

/// 카메라 화면 위에 삼분할 격자, 목표 얼굴 위치·눈높이, 현재 얼굴, 관절 잘림, 수평계를 그린다.
class CompositionOverlayPainter extends CustomPainter {
  CompositionOverlayPainter({
    required this.result,
    required this.subject,
    required this.rollDeg,
    required this.showGrid,
  });

  final GuideResult result;
  final PortraitFeatures? subject;
  final double rollDeg;
  final bool showGrid;

  static const _good = Color(0xFF4ADE80);
  static const _target = Color(0xFFFFD54F);
  static const _warn = Color(0xFFFF6B6B);

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) _drawGrid(canvas, size);
    _drawTarget(canvas, size);
    if (subject != null) _drawSubject(canvas, size, subject!);
    _drawLevel(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.4)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), p);
      canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), p);
    }
  }

  /// 얼굴 반지름(px): 눈~어깨 거리의 약 60%
  double _headRadius(double headSize, Size size) => math.max(10, headSize * size.height * 0.6);

  void _drawTarget(Canvas canvas, Size size) {
    final color = result.ready ? _good : _target;
    final t = result.template;
    final eyeY = t.eyeY * size.height;
    final center = Offset(result.targetX * size.width, eyeY);
    final r = _headRadius(t.headSize, size);

    // 목표 눈높이 선
    _dashed(
      canvas,
      Path()
        ..moveTo(0, eyeY)
        ..lineTo(size.width, eyeY),
      Paint()
        ..color = color.withValues(alpha: 0.6)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke,
    );
    // 목표 얼굴 위치 (눈높이가 얼굴 원의 위쪽 40% 지점에 오도록)
    final faceCenter = center.translate(0, r * 0.2);
    canvas.drawCircle(faceCenter, r, Paint()..color = color.withValues(alpha: 0.12));
    _dashed(
      canvas,
      Path()..addOval(Rect.fromCircle(center: faceCenter, radius: r)),
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawSubject(Canvas canvas, Size size, PortraitFeatures s) {
    final r = _headRadius(s.headSize, size);
    final c = Offset(s.headX * size.width, s.eyeY * size.height + r * 0.2);
    final paint = Paint()
      ..color = (result.ready ? _good : Colors.white).withValues(alpha: 0.9)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(c, r, paint);

    // 시선 방향 표시
    if (s.faceDir != 0) {
      final dir = s.faceDir.toDouble();
      final tip = c.translate(dir * (r + 18), 0);
      canvas.drawLine(c.translate(dir * r, 0), tip, paint);
      canvas.drawLine(tip, tip.translate(-dir * 7, -6), paint);
      canvas.drawLine(tip, tip.translate(-dir * 7, 6), paint);
    }

    // 현재 → 목표 화살표
    if (!result.ready) {
      final target = Offset(result.targetX * size.width, result.template.eyeY * size.height + r * 0.2);
      canvas.drawLine(
        c,
        target,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.6)
          ..strokeWidth = 2,
      );
    }

    // 관절 잘림: 화면 아래 끝을 빨갛게
    if (s.jointCut != null) {
      canvas.drawRect(
        Rect.fromLTWH(0, size.height - 6, size.width, 6),
        Paint()..color = _warn.withValues(alpha: 0.85),
      );
    }
    if (s.topY < -0.01 && s.shot != 'face') {
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, 6), Paint()..color = _warn.withValues(alpha: 0.85));
    }
  }

  void _drawLevel(Canvas canvas, Size size) {
    final level = rollDeg.abs() <= 2;
    final c = Offset(size.width / 2, size.height * 0.92);
    final len = size.width * 0.12;
    final ref = Paint()
      ..color = Colors.white.withValues(alpha: 0.5)
      ..strokeWidth = 2;
    canvas.drawLine(c - Offset(len * 1.4, 0), c - Offset(len * 1.1, 0), ref);
    canvas.drawLine(c + Offset(len * 1.1, 0), c + Offset(len * 1.4, 0), ref);
    // 실제 수평선은 휴대폰이 기운 반대 방향으로 기울어 보인다.
    final a = -rollDeg * math.pi / 180;
    final d = Offset(math.cos(a), math.sin(a)) * len;
    canvas.drawLine(
      c - d,
      c + d,
      Paint()
        ..color = level ? _good : Colors.orangeAccent
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
  }

  void _dashed(Canvas canvas, Path path, Paint p, {double dash = 8, double gap = 5}) {
    for (final m in path.computeMetrics()) {
      var d = 0.0;
      while (d < m.length) {
        canvas.drawPath(m.extractPath(d, math.min(d + dash, m.length)), p);
        d += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(CompositionOverlayPainter old) =>
      old.result != result || old.subject != subject || old.rollDeg != rollDeg || old.showGrid != showGrid;
}
