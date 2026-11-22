import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../license/license.dart';
import '../license/license_public_key.dart';
import '../license/license_store.dart';

/// 사용 기간 키가 유효할 때만 [child] 를 보여준다.
/// 기간이 끝나면(앱을 쓰는 도중이어도) 키 입력 화면으로 바뀐다.
class LicenseGate extends StatefulWidget {
  const LicenseGate({super.key, required this.child});

  final Widget child;

  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> with WidgetsBindingObserver {
  /// 남은 기간이 이보다 짧으면 미리 알려준다.
  static const _warnBefore = Duration(days: 5);

  final _verifier = LicenseVerifier(licensePublicKey);
  final _store = LicenseStore();
  LicenseCheck? _check;
  Timer? _expiryTimer;
  bool _entering = false; // 기간이 남았는데 새 키를 입력하는 중
  bool _warned = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<LicenseCheck> _evaluate(String? key) async {
    final now = DateTime.now().toUtc();
    final check = await _verifier.check(key, now: now, lastSeen: await _store.loadLastSeen());
    if (check.status != LicenseStatus.clockTampered) await _store.bumpLastSeen(now);
    return check;
  }

  Future<void> _refresh() async {
    final check = await _evaluate(await _store.loadKey());
    if (!mounted) return;
    setState(() => _check = check);
    _scheduleExpiry(check);
    _maybeWarn(check);
  }

  void _scheduleExpiry(LicenseCheck check) {
    _expiryTimer?.cancel();
    if (!check.isValid) return;
    final left = check.info!.remaining(DateTime.now().toUtc());
    // Timer 는 너무 긴 시간을 못 다루므로 최대 하루 단위로 다시 확인한다.
    final wait = left < const Duration(days: 1) ? left + const Duration(seconds: 1) : const Duration(days: 1);
    _expiryTimer = Timer(wait, _refresh);
  }

  void _maybeWarn(LicenseCheck check) {
    if (_warned || !check.isValid) return;
    final left = check.info!.remaining(DateTime.now().toUtc());
    if (left > _warnBefore) return;
    _warned = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final days = left.inHours ~/ 24;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(days > 0 ? '사용 기간이 $days일 남았어요.' : '사용 기간이 오늘 끝나요.'),
        action: SnackBarAction(label: '새 키 입력', onPressed: () => setState(() => _entering = true)),
      ));
    });
  }

  /// 입력한 키를 확인하고, 유효하면 저장한다. 결과를 돌려준다.
  Future<LicenseCheck> _submit(String raw) async {
    final key = LicenseVerifier.normalize(raw);
    final check = await _evaluate(key);
    if (check.isValid) {
      await _store.saveKey(key);
      if (mounted) {
        setState(() {
          _check = check;
          _entering = false;
        });
        _scheduleExpiry(check);
      }
    }
    return check;
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    if (check == null) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));
    }
    if (check.isValid && !_entering) return widget.child;
    return LicenseScreen(
      current: check,
      onSubmit: _submit,
      onCancel: check.isValid ? () => setState(() => _entering = false) : null,
    );
  }
}

class LicenseScreen extends StatefulWidget {
  const LicenseScreen({super.key, required this.current, required this.onSubmit, this.onCancel});

  final LicenseCheck current;
  final Future<LicenseCheck> Function(String key) onSubmit;
  final VoidCallback? onCancel;

  @override
  State<LicenseScreen> createState() => _LicenseScreenState();
}

class _LicenseScreenState extends State<LicenseScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) _controller.text = data!.text!.trim();
  }

  Future<void> _register() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final check = await widget.onSubmit(_controller.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = check.isValid ? null : check.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cur = widget.current;
    final statusColor = cur.isValid ? Colors.greenAccent : Colors.orangeAccent;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('사용 키 입력'),
        backgroundColor: Colors.black,
        leading: widget.onCancel == null ? null : BackButton(onPressed: widget.onCancel),
        automaticallyImplyLeading: false,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(cur.message, style: TextStyle(color: statusColor, fontSize: 16)),
            const SizedBox(height: 24),
            TextField(
              controller: _controller,
              minLines: 3,
              maxLines: 6,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'CS1-...',
                errorText: _error,
                errorMaxLines: 3,
                suffixIcon: IconButton(icon: const Icon(Icons.content_paste), tooltip: '붙여넣기', onPressed: _paste),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _register,
              child: _busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('등록'),
            ),
          ],
        ),
      ),
    );
  }
}
