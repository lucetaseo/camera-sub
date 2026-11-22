import 'package:shared_preferences/shared_preferences.dart';

/// 입력한 키와 '마지막으로 본 시각' 을 기기에 저장한다.
class LicenseStore {
  static const _keyKey = 'license.key';
  static const _lastSeenKey = 'license.lastSeenMs';

  Future<String?> loadKey() async => (await SharedPreferences.getInstance()).getString(_keyKey);

  Future<void> saveKey(String key) async => (await SharedPreferences.getInstance()).setString(_keyKey, key);

  Future<DateTime?> loadLastSeen() async {
    final ms = (await SharedPreferences.getInstance()).getInt(_lastSeenKey);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  /// 지금 시각이 저장된 값보다 나중일 때만 갱신한다 (되돌린 시계로 덮어쓰지 않도록).
  Future<void> bumpLastSeen(DateTime now) async {
    final prefs = await SharedPreferences.getInstance();
    final prev = prefs.getInt(_lastSeenKey) ?? 0;
    final ms = now.millisecondsSinceEpoch;
    if (ms > prev) await prefs.setInt(_lastSeenKey, ms);
  }
}
