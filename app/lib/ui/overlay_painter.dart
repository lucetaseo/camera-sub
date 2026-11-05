import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../composition/guide_engine.dart';
import '../composition/templates.dart';

/// 카메라 화면 위에 삼분할 격자, 목표 구도, 현재 인물 위치, 수평계를 그린다.
class CompositionOverlayPainter extends CustomPainter {
  CompositionOverlayPainter({
    required this.template,
    required this.subject,
    required this.rollDeg,
    required this.ready,
    required this.showGrid,
  });

  final CompositionTemplate template;
  final SubjectBox? subject;
  final double rollDeg;
  final bool ready;
  final bool showGrid;

  static const _good = Color(0xFF4ADE80);
  static const _target = Color(0xFFFFD54F);

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) _drawGrid(canvas, size);
    _drawTemplate(canvas, size);
    if (subject != null) _drawSubject(canvas, size, subject!);
    _drawLevel(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    for (var i = 1; i <= 2; i++) {
      final x = size.width * i / 3;
      final y = size.height * i / 3;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }

  void _drawTemplate(Canvas canvas, Size size) {
    final color = ready ? _good : _target;
    final h = template.subjectH * size.height;
    final w = h * 0.38; // 서 있는 사람의 대략적인 비율
    final center = Offset(template.subjectCx * size.width, template.subjectCy * size.height);
    final rect = Rect.fromCenter(center: center, width: w, height: h);

    // 사람 실루엣(머리 + 몸) 모양의 목표 위치
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final fill = Paint()..color = color.withValues(alpha: 0.12);
    final headR = w * 0.28;
    final headC = Offset(center.dx, rect.top + headR);
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(rect.left, headC.dy + headR * 1.15, rect.right, rect.bottom),
      Radius.circular(w * 0.3),
    );
    canvas.drawCircle(headC, headR, fill);
    canvas.drawRRect(body, fill);
    _dashedCircle(canvas, headC, headR, stroke);
    _dashedPath(canvas, Path()..addRRect(body), stroke);

    if (template.horizonY != null) {
      final y = template.horizonY! * size.height;
      _dashedPath(
        canvas,
        Path()
          ..moveTo(0, y)
          ..lineTo(size.width, y),
        Paint()
          ..color = Colors.lightBlueAccent.withValues(alpha: 0.8)
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
  }

  void _drawSubject(Canvas canvas, Size size, SubjectBox s) {
    final rect = Rect.fromLTRB(s.left * size.width, s.top * size.height, s.right * size.width, s.bottom * size.height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()
        ..color = (ready ? _good : Colors.white).withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // 현재 중심 → 목표 중심 화살표
    if (!ready) {
      final from = Offset(s.cx * size.width, s.cy * size.height);
      final to = Offset(template.subjectCx * size.width, template.subjectCy * size.height);
      final p = Paint()
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 2;
      canvas.drawLine(from, to, p);
      canvas.drawCircle(from, 4, p);
    }
  }

  void _drawLevel(Canvas canvas, Size size) {
    final level = rollDeg.abs() <= 2;
    final c = Offset(size.width / 2, size.height / 2);
    final len = size.width * 0.18;
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

  void _dashedCircle(Canvas canvas, Offset c, double r, Paint p) =>
      _dashedPath(canvas, Path()..addOval(Rect.fromCircle(center: c, radius: r)), p);

  void _dashedPath(Canvas canvas, Path path, Paint p, {double dash = 8, double gap = 5}) {
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
      old.template != template ||
      old.subject != subject ||
      old.rollDeg != rollDeg ||
      old.ready != ready ||
      old.showGrid != showGrid;
}
