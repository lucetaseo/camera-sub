import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../composition/guide_engine.dart';
import '../composition/templates.dart';
import '../composition/scene_classifier.dart';
import '../vision/frame_analyzer.dart';
import 'overlay_painter.dart';

const _album = 'CameraSub';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key, required this.scenes, required this.sceneRules});

  final List<Scene> scenes;
  final SceneRules sceneRules;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  final _engine = const GuideEngine();
  final _smoother = SubjectSmoother();
  FrameAnalyzer? _detector;
  late final SceneClassifier _classifier;
  CameraController? _controller;
  StreamSubscription<AccelerometerEvent>? _accelSub;

  String? _error;
  bool _autoScene = true;
  int _sceneIndex = 0; // 수동 선택일 때
  CompositionTemplate? _locked; // null 이면 자동으로 가까운 구도 선택
  SubjectBox? _subject;
  double _roll = 0;
  bool _showGrid = true;
  bool _capturing = false;
  bool _flashOn = false;
  File? _lastShot;
  double _zoom = 1, _minZoom = 1, _maxZoom = 1, _zoomAtPinchStart = 1;

  Scene get _scene {
    if (!_autoScene) return widget.scenes[_sceneIndex];
    final id = _classifier.current;
    return widget.scenes.firstWhere((s) => s.id == id, orElse: () => widget.scenes[_fallbackIndex]);
  }

  int get _fallbackIndex {
    final i = widget.scenes.indexWhere((s) => s.id == widget.sceneRules.fallbackScene);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _classifier = SceneClassifier(widget.sceneRules, availableScenes: widget.scenes.map((s) => s.id).toSet());
    _accelSub = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((e) {
      final roll = math.atan2(e.x, e.y) * 180 / math.pi;
      // 저역 통과 필터로 손떨림 제거
      final next = _roll + (roll - _roll) * 0.2;
      if ((next - _roll).abs() > 0.05 && mounted) setState(() => _roll = next);
    });
    _startCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    _stopCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed && _controller == null) {
      _startCamera();
    }
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(
        back,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.nv21 : ImageFormatGroup.bgra8888,
      );
      await controller.initialize();
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      await controller.setFlashMode(FlashMode.off);
      _minZoom = await controller.getMinZoomLevel();
      _maxZoom = math.min(await controller.getMaxZoomLevel(), 8);
      _zoom = _minZoom;
      _detector = FrameAnalyzer()..sceneEnabled = _autoScene;
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
      await _startStream();
    } on CameraException catch (e) {
      setState(() => _error = e.code == 'CameraAccessDenied' ? '카메라 권한을 허용해 주세요.' : '카메라를 열 수 없어요 (${e.code})');
    } catch (e) {
      setState(() => _error = '카메라를 열 수 없어요: $e');
    }
  }

  Future<void> _startStream() async {
    final c = _controller;
    if (c == null || c.value.isStreamingImages) return;
    await c.startImageStream((image) async {
      final r = await _detector?.process(image, c.description);
      if (r == null || !mounted) return;
      setState(() {
        _subject = _smoother.update(r.subject);
        if (_autoScene && r.labels != null) {
          final before = _classifier.current;
          final after = _classifier.update(r.labels!, _subject);
          if (before != after) _locked = null; // 장면이 바뀌면 템플릿 고정 해제
        }
      });
    });
  }

  Future<void> _stopCamera() async {
    final c = _controller;
    final d = _detector;
    _controller = null;
    _detector = null;
    if (c != null) {
      if (c.value.isStreamingImages) await c.stopImageStream();
      await c.dispose();
    }
    await d?.close();
  }

  Future<void> _takePicture() async {
    final c = _controller;
    if (c == null || _capturing) return;
    setState(() => _capturing = true);
    HapticFeedback.mediumImpact();
    try {
      // 일부 기기는 프레임 분석 중 촬영이 불안정해서 잠깐 멈춘다.
      if (c.value.isStreamingImages) await c.stopImageStream();
      final shot = await c.takePicture();
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putImage(shot.path, album: _album);
      setState(() => _lastShot = File(shot.path));
      _toast('갤러리의 "$_album" 앨범에 저장했어요');
    } on GalException catch (e) {
      _toast('저장 실패: ${e.type.message}');
    } catch (e) {
      _toast('촬영 실패: $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
      if (_controller == c) await _startStream();
    }
  }

  Future<void> _toggleFlash() async {
    final c = _controller;
    if (c == null) return;
    final on = !_flashOn;
    await c.setFlashMode(on ? FlashMode.auto : FlashMode.off);
    setState(() => _flashOn = on);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  void _setAutoScene(bool auto, {int? index}) {
    setState(() {
      _autoScene = auto;
      if (index != null) _sceneIndex = index;
      _locked = null;
    });
    _detector?.sceneEnabled = auto;
  }

  void _cycleTemplate() {
    final ts = _scene.templates;
    setState(() {
      if (_locked == null) {
        _locked = ts.first;
      } else {
        final i = ts.indexOf(_locked!);
        _locked = i + 1 < ts.length ? ts[i + 1] : null; // 마지막 다음은 자동
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final result = _engine.evaluate(scene: _scene, subject: _subject, rollDeg: _roll, lockedTemplate: _locked);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _sceneBar(),
            _templateBar(result),
            Expanded(
              child: Center(
                child: _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
                      )
                    : c == null || !c.value.isInitialized
                        ? const CircularProgressIndicator()
                        : _preview(c, result),
              ),
            ),
            _hintBanner(result),
            _controls(result),
          ],
        ),
      ),
    );
  }

  Widget _preview(CameraController c, GuideResult result) {
    return GestureDetector(
      onScaleStart: (_) => _zoomAtPinchStart = _zoom,
      onScaleUpdate: (d) {
        final z = (_zoomAtPinchStart * d.scale).clamp(_minZoom, _maxZoom);
        if ((z - _zoom).abs() > 0.01) {
          _zoom = z;
          c.setZoomLevel(z);
          setState(() {});
        }
      },
      child: AspectRatio(
        // 세로 화면이므로 카메라 비율(가로/세로)을 뒤집는다.
        aspectRatio: 1 / c.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(c),
            CustomPaint(
              painter: CompositionOverlayPainter(
                template: result.template,
                subject: _subject,
                rollDeg: _roll,
                ready: result.ready,
                showGrid: _showGrid,
              ),
            ),
            if (_zoom > _minZoom + 0.05)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(child: _pill('${_zoom.toStringAsFixed(1)}x')),
              ),
            if (_capturing) Container(color: Colors.white.withValues(alpha: 0.3)),
          ],
        ),
      ),
    );
  }

  Widget _sceneBar() => SizedBox(
        height: 48,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          itemCount: widget.scenes.length + 1,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            if (i == 0) {
              return ChoiceChip(
                avatar: const Icon(Icons.auto_awesome, size: 16),
                label: Text(_autoScene ? '자동 · ${_scene.label}' : '자동'),
                selected: _autoScene,
                onSelected: (_) => _setAutoScene(true),
              );
            }
            final idx = i - 1;
            return ChoiceChip(
              label: Text(widget.scenes[idx].label),
              selected: !_autoScene && idx == _sceneIndex,
              onSelected: (_) => _setAutoScene(false, index: idx),
            );
          },
        ),
      );

  Widget _templateBar(GuideResult result) => InkWell(
        onTap: _cycleTemplate,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              _pill(_locked == null ? '자동' : '고정'),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result.template.description,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Icon(Icons.swap_horiz, color: Colors.white54, size: 18),
            ],
          ),
        ),
      );

  Widget _hintBanner(GuideResult result) {
    final hint = result.hints.first;
    final color = result.ready ? const Color(0xFF4ADE80) : Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Icon(_iconFor(hint.action), color: color, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(hint.message, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w600)),
                if (result.hints.length > 1)
                  Text(
                    '다음: ${result.hints[1].message}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          Text('${result.score}', style: TextStyle(color: color, fontSize: 24, fontWeight: FontWeight.bold)),
          const Text('점', style: TextStyle(color: Colors.white54)),
        ],
      ),
    );
  }

  Widget _controls(GuideResult result) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: _lastShot == null ? null : () => Gal.open(),
              child: Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white38),
                  image: _lastShot == null ? null : DecorationImage(image: FileImage(_lastShot!), fit: BoxFit.cover),
                ),
                child: _lastShot == null ? const Icon(Icons.photo_library_outlined, color: Colors.white38) : null,
              ),
            ),
            GestureDetector(
              onTap: _takePicture,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: result.ready ? const Color(0xFF4ADE80) : Colors.white, width: 5),
                ),
                padding: const EdgeInsets.all(4),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _capturing ? Colors.white54 : Colors.white,
                  ),
                ),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  onPressed: () => setState(() => _showGrid = !_showGrid),
                  icon: Icon(_showGrid ? Icons.grid_on : Icons.grid_off, color: Colors.white),
                  tooltip: '격자',
                ),
                IconButton(
                  onPressed: _toggleFlash,
                  icon: Icon(_flashOn ? Icons.flash_auto : Icons.flash_off, color: Colors.white),
                  tooltip: '플래시',
                ),
              ],
            ),
          ],
        ),
      );

  Widget _pill(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
        child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
      );

  static IconData _iconFor(HintAction a) => switch (a) {
        HintAction.levelLeftUp => Icons.rotate_right,
        HintAction.levelRightUp => Icons.rotate_left,
        HintAction.panLeft => Icons.arrow_back,
        HintAction.panRight => Icons.arrow_forward,
        HintAction.tiltUp => Icons.arrow_upward,
        HintAction.tiltDown => Icons.arrow_downward,
        HintAction.stepBack => Icons.zoom_out_map,
        HintAction.stepCloser => Icons.center_focus_strong,
        HintAction.findSubject => Icons.person_search,
        HintAction.ready => Icons.check_circle,
      };
}
