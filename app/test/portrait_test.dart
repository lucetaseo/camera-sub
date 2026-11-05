import 'dart:convert';
import 'dart:io';

import 'package:camera_sub/composition/portrait.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final fixtures = jsonDecode(File('../shared/portrait_fixtures.json').readAsStringSync()) as Map<String, dynamic>;

  Map<String, Kp> kps(Map<String, dynamic> raw) => {
        for (final e in raw.entries)
          e.key: Kp((e.value[0] as num).toDouble(), (e.value[1] as num).toDouble(), (e.value[2] as num) != 0),
      };

  group('learner(Python) 와 같은 결과 (shared/portrait_fixtures.json)', () {
    for (final c in (fixtures['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['name'] as String, () {
        final f = computeFeatures(kps(c['keypoints'] as Map<String, dynamic>));
        final exp = c['expected'] as Map<String, dynamic>?;
        if (exp == null) {
          expect(f, isNull);
          return;
        }
        expect(f, isNotNull);
        expect(f!.shot, exp['shot']);
        expect(f.headX, closeTo((exp['head_x'] as num).toDouble(), 1e-5));
        expect(f.eyeY, closeTo((exp['eye_y'] as num).toDouble(), 1e-5));
        expect(f.headSize, closeTo((exp['head_size'] as num).toDouble(), 1e-5));
        expect(f.topY, closeTo((exp['top_y'] as num).toDouble(), 1e-5));
        expect(f.faceDir, exp['face_dir']);
        expect(f.jointCut, exp['joint_cut']);
        expect(f.canonicalX, closeTo((exp['canonical_x'] as num).toDouble(), 1e-5));
      });
    }
  });

  test('KeypointSmoother 는 위치를 부드럽게 하고 오래 놓치면 지운다', () {
    final s = KeypointSmoother(alpha: 0.5, maxMissedFrames: 1);
    s.update({'nose': const Kp(0.2, 0.2, true)});
    expect(s.update({'nose': const Kp(0.4, 0.2, true)})!['nose']!.x, closeTo(0.3, 1e-9));
    expect(s.update(null), isNotNull);
    expect(s.update(null), isNull);
  });
}
