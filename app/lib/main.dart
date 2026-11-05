import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'composition/templates.dart';
import 'ui/camera_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  // learner/ 로 학습한 결과를 assets/templates.json 에 덮어쓰면 앱에 반영된다.
  final scenes = parseTemplates(await rootBundle.loadString('assets/templates.json'));
  runApp(CameraSubApp(scenes: scenes));
}

class CameraSubApp extends StatelessWidget {
  const CameraSubApp({super.key, required this.scenes});

  final List<Scene> scenes;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '구도 카메라',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF4ADE80), brightness: Brightness.dark, useMaterial3: true),
      home: CameraScreen(scenes: scenes),
    );
  }
}
