// 사용 기간 키 (라이선스 키) 검증.
//
// 키 형식: CS1-<payload>.<signature>   (둘 다 base64url, 패딩 없음)
//   payload   = UTF-8 JSON {"v":1,"id":"..","name":"..","iat":발급(유닉스초),"exp":만료(유닉스초)}
//   signature = payload 바이트에 대한 Ed25519 서명
//
// 키는 license_tool/license_tool.py 가 개인키로 서명해서 발급하고,
// 앱은 공개키(license_public_key.dart)로 서명만 확인한다. 그래서 인터넷 없이도 검증되고,
// 앱을 뜯어봐도 공개키로는 새 키를 만들 수 없다.
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const licensePrefix = 'CS1-';

/// 기기 시계를 이만큼 넘게 과거로 돌리면 시간 조작으로 본다.
const clockTolerance = Duration(days: 1);

enum LicenseStatus {
  valid,
  missing,
  notConfigured,
  invalidFormat,
  badSignature,
  expired,
  clockTampered,
}

class LicenseInfo {
  const LicenseInfo({required this.id, required this.name, required this.issuedAt, required this.expiresAt});

  final String id;
  final String name;
  final DateTime issuedAt;
  final DateTime expiresAt;

  Duration remaining(DateTime now) => expiresAt.difference(now);
}

class LicenseCheck {
  const LicenseCheck(this.status, [this.info]);

  final LicenseStatus status;
  final LicenseInfo? info;

  bool get isValid => status == LicenseStatus.valid;

  String get message => switch (status) {
        LicenseStatus.valid => '사용 가능 · ${formatDate(info!.expiresAt)} 까지',
        LicenseStatus.missing => '사용 키를 입력해 주세요.',
        LicenseStatus.notConfigured => '앱에 공개키가 설정되지 않았어요. (license_tool.py init 을 먼저 실행하세요)',
        LicenseStatus.invalidFormat => '키 형식이 올바르지 않아요. 받은 키 전체를 그대로 붙여 넣어 주세요.',
        LicenseStatus.badSignature => '유효하지 않은 키예요.',
        LicenseStatus.expired => '사용 기간이 끝났어요 (${formatDate(info!.expiresAt)}). 새 키를 받아 입력해 주세요.',
        LicenseStatus.clockTampered => '기기 날짜/시간이 올바르지 않아요. 자동 시간 설정을 켜 주세요.',
      };
}

String formatDate(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}.${two(l.month)}.${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

class LicenseVerifier {
  LicenseVerifier(this.publicKey);

  /// Ed25519 공개키 32바이트.
  final List<int> publicKey;

  /// 붙여 넣은 텍스트에서 공백·줄바꿈을 지운다 (메신저로 받으면 줄이 바뀌기도 한다).
  static String normalize(String raw) => raw.replaceAll(RegExp(r'\s+'), '');

  /// [key] 를 검사한다.
  /// [lastSeen] 은 이 기기에서 앱이 마지막으로 본 시각 (시계를 되돌렸는지 확인용).
  Future<LicenseCheck> check(String? key, {required DateTime now, DateTime? lastSeen}) async {
    if (publicKey.length != 32) return const LicenseCheck(LicenseStatus.notConfigured);
    if (key == null || normalize(key).isEmpty) return const LicenseCheck(LicenseStatus.missing);

    final k = normalize(key);
    if (!k.startsWith(licensePrefix)) return const LicenseCheck(LicenseStatus.invalidFormat);
    final parts = k.substring(licensePrefix.length).split('.');
    if (parts.length != 2) return const LicenseCheck(LicenseStatus.invalidFormat);

    final List<int> payload, sig;
    try {
      payload = base64Url.decode(base64Url.normalize(parts[0]));
      sig = base64Url.decode(base64Url.normalize(parts[1]));
    } on FormatException {
      return const LicenseCheck(LicenseStatus.invalidFormat);
    }
    if (sig.length != 64) return const LicenseCheck(LicenseStatus.invalidFormat);

    final ok = await Ed25519().verify(
      payload,
      signature: Signature(sig, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
    if (!ok) return const LicenseCheck(LicenseStatus.badSignature);

    final LicenseInfo info;
    try {
      final j = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if (j['v'] != 1) return const LicenseCheck(LicenseStatus.invalidFormat);
      DateTime t(String f) => DateTime.fromMillisecondsSinceEpoch((j[f] as num).toInt() * 1000, isUtc: true);
      info = LicenseInfo(
        id: j['id'] as String,
        name: (j['name'] as String?) ?? '',
        issuedAt: t('iat'),
        expiresAt: t('exp'),
      );
    } catch (_) {
      return const LicenseCheck(LicenseStatus.invalidFormat);
    }

    // 시계를 과거로 돌려서 기간을 늘리는 것을 막는다:
    // 키 발급 시각보다, 또는 이 기기에서 이미 본 시각보다 지금이 한참 이르면 조작으로 본다.
    final floor = [info.issuedAt, if (lastSeen != null) lastSeen].reduce((a, b) => a.isAfter(b) ? a : b);
    if (now.isBefore(floor.subtract(clockTolerance))) return LicenseCheck(LicenseStatus.clockTampered, info);

    if (!now.isBefore(info.expiresAt)) return LicenseCheck(LicenseStatus.expired, info);
    return LicenseCheck(LicenseStatus.valid, info);
  }
}
