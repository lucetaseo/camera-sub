import 'dart:convert';
import 'dart:io';

import 'package:camera_sub/license/license.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // license_tool(Python) 이 테스트용 키쌍으로 만든 키
  final f = jsonDecode(File('../shared/license_fixtures.json').readAsStringSync()) as Map<String, dynamic>;
  final verifier = LicenseVerifier((f['publicKey'] as List).cast<int>());
  final valid = f['valid'] as String;
  final iat = DateTime.parse(f['issuedAt'] as String);
  final exp = DateTime.parse(f['expiresAt'] as String);

  test('기간 안이면 사용 가능', () async {
    final c = await verifier.check(valid, now: iat.add(const Duration(days: 10)));
    expect(c.status, LicenseStatus.valid);
    expect(c.info!.name, '홍길동');
    expect(c.info!.expiresAt, exp);
  });

  test('만료 시각이 지나면 막힘', () async {
    expect((await verifier.check(valid, now: exp)).status, LicenseStatus.expired);
    expect((await verifier.check(valid, now: exp.subtract(const Duration(seconds: 1)))).status, LicenseStatus.valid);
  });

  test('메신저에서 줄바꿈이 섞여도 인식', () async {
    final broken = '${valid.substring(0, 30)}\n  ${valid.substring(30)} ';
    expect((await verifier.check(broken, now: iat)).status, LicenseStatus.valid);
  });

  test('다른 개인키로 만든 키, 변조한 키는 거절', () async {
    expect((await verifier.check(f['otherSigner'] as String, now: iat)).status, LicenseStatus.badSignature);
    final tampered = valid.replaceFirst('CS1-eyJ2', 'CS1-eyJ3');
    expect((await verifier.check(tampered, now: iat)).status, isNot(LicenseStatus.valid));
  });

  test('형식이 틀리거나 비어 있으면', () async {
    expect((await verifier.check(null, now: iat)).status, LicenseStatus.missing);
    expect((await verifier.check('  ', now: iat)).status, LicenseStatus.missing);
    expect((await verifier.check('abc', now: iat)).status, LicenseStatus.invalidFormat);
    expect((await verifier.check('CS1-@@@.###', now: iat)).status, LicenseStatus.invalidFormat);
  });

  test('시계를 과거로 돌리면 막힘', () async {
    // 발급 전으로 돌림
    expect((await verifier.check(valid, now: iat.subtract(const Duration(days: 3)))).status,
        LicenseStatus.clockTampered);
    // 만료 뒤에 앱을 본 적이 있는데 기간 안으로 돌림
    final c = await verifier.check(valid,
        now: iat.add(const Duration(days: 5)), lastSeen: exp.add(const Duration(days: 2)));
    expect(c.status, LicenseStatus.clockTampered);
    // 몇 시간 정도 어긋나는 건 허용
    expect(
        (await verifier.check(valid,
                now: iat.add(const Duration(days: 5)), lastSeen: iat.add(const Duration(days: 5, hours: 3))))
            .status,
        LicenseStatus.valid);
  });

  test('공개키가 없으면 어떤 키도 안 받음', () async {
    expect((await LicenseVerifier(const []).check(valid, now: iat)).status, LicenseStatus.notConfigured);
  });
}
