import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composition/scene_classifier.dart';
import 'composition/templates.dart';
import 'ui/camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // learner/ 로 학습한 결과를 assets/templates.json 에 덮어쓰면 앱에 반영된다.
  final shots = parseTemplates(await rootBundle.loadString('assets/templates.json'));
  final sceneRules = SceneRules.fromJson(await rootBundle.loadString('assets/scene_rules.json'));
  runApp(CameraSubApp(shots: shots, sceneRules: sceneRules));
}

class CameraSubApp extends StatelessWidget {
  const CameraSubApp({super.key, required this.shots, required this.sceneRules});

  final List<Shot> shots;
  final SceneRules sceneRules;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '구도 카메라',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4ADE80), brightness: Brightness.dark, useMaterial3: true),
      home: CameraScreen(shots: shots, sceneRules: sceneRules),
    );
  }
}
