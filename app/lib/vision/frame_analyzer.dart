import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_pose_detection/google_mlkit_pose_detection.dart';

import '../composition/guide_engine.dart';
import '../composition/scene_classifier.dart';

/// 한 프레임의 분석 결과. [labels] 는 장면 인식을 돌린 프레임에만 들어 있다.
class FrameAnalysis {
  const FrameAnalysis(this.subject, this.labels);

  final SubjectBox? subject;
  final List<SceneLabel>? labels;
}

/// ML Kit 로 카메라 프레임을 분석한다.
/// - 포즈 검출: 매 프레임, 가장 큰 인물의 박스
/// - 이미지 라벨링(장면 인식): [labelInterval] 마다 한 번 (배터리·속도 절약)
class FrameAnalyzer {
  FrameAnalyzer({this.labelInterval = const Duration(milliseconds: 800)})
      : _pose = PoseDetector(options: PoseDetectorOptions()),
        _labeler = ImageLabeler(options: ImageLabelerOptions(confidenceThreshold: 0.4));

  final Duration labelInterval;
  final PoseDetector _pose;
  final ImageLabeler _labeler;
  bool _busy = false;
  bool sceneEnabled = true;
  DateTime _lastLabel = DateTime.fromMillisecondsSinceEpoch(0);

  /// 앞 프레임을 처리 중이면 null 을 돌려주고 건너뛴다(실시간 유지).
  Future<FrameAnalysis?> process(CameraImage image, CameraDescription camera) async {
    if (_busy) return null;
    _busy = true;
    try {
      final input = _toInputImage(image, camera);
      if (input == null) return const FrameAnalysis(null, null);
      final now = DateTime.now();
      final doLabels = sceneEnabled && now.difference(_lastLabel) >= labelInterval;
      if (doLabels) _lastLabel = now;
      final results = await Future.wait([
        _pose.processImage(input),
        if (doLabels) _labeler.processImage(input),
      ]);
      final poses = results[0] as List<Pose>;
      final labels = doLabels
          ? (results[1] as List<ImageLabel>).map((l) => SceneLabel(l.label, l.confidence)).toList()
          : null;
      return FrameAnalysis(_largestSubject(poses, image, camera), labels);
    } catch (e) {
      debugPrint('frame analysis failed: $e');
      return const FrameAnalysis(null, null);
    } finally {
      _busy = false;
    }
  }

  Future<void> close() async {
    await _pose.close();
    await _labeler.close();
  }

  InputImage? _toInputImage(CameraImage image, CameraDescription camera) {
    final rotation = InputImageRotationValue.fromRawValue(camera.sensorOrientation);
    if (rotation == null || image.planes.isEmpty) return null;
    // Android(CameraX)에 nv21 을 요청하면 NV21 데이터가 한 plane 으로 온다.
    final format = Platform.isAndroid ? InputImageFormat.nv21 : InputImageFormatValue.fromRawValue(image.format.raw);
    if (format == null) return null;
    final plane = image.planes.first;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  SubjectBox? _largestSubject(List<Pose> poses, CameraImage image, CameraDescription camera) {
    // 결과 좌표는 '세워진' 이미지 기준. Android 는 센서가 가로라서 가로/세로가 바뀐다.
    final swap = Platform.isAndroid && (camera.sensorOrientation == 90 || camera.sensorOrientation == 270);
    final w = (swap ? image.height : image.width).toDouble();
    final h = (swap ? image.width : image.height).toDouble();

    SubjectBox? best;
    for (final pose in poses) {
      final pts = pose.landmarks.values.where((l) => l.likelihood >= 0.3).toList();
      if (pts.length < 4) continue;
      var minX = double.infinity, minY = double.infinity, maxX = -double.infinity, maxY = -double.infinity;
      for (final p in pts) {
        if (p.x < minX) minX = p.x;
        if (p.x > maxX) maxX = p.x;
        if (p.y < minY) minY = p.y;
        if (p.y > maxY) maxY = p.y;
      }
      // 랜드마크는 눈/코에서 끝나므로 머리 꼭대기까지 늘린다 (learner 와 같은 8%).
      minY -= (maxY - minY) * 0.08;
      final box = SubjectBox(
        (minX / w).clamp(0.0, 1.0),
        (minY / h).clamp(0.0, 1.0),
        (maxX / w).clamp(0.0, 1.0),
        (maxY / h).clamp(0.0, 1.0),
      );
      if (best == null || box.height > best.height) best = box;
    }
    return best;
  }
}
