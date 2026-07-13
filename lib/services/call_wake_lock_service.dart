import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class CallWakeLockService {
  CallWakeLockService._();

  static final CallWakeLockService instance = CallWakeLockService._();

  static const MethodChannel _channel =
      MethodChannel('friendify/native_call_bridge');

  final Set<String> _holders = <String>{};

  Future<void> enable(String holder) async {
    final safeHolder = holder.trim().isEmpty ? 'call' : holder.trim();
    final wasEmpty = _holders.isEmpty;
    _holders.add(safeHolder);
    if (!wasEmpty) {
      debugPrint('call_wake_lock.enabled owner=$safeHolder');
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'setCallKeepScreenOn',
        <String, Object?>{'enabled': true, 'owner': safeHolder},
      );
      debugPrint('call_wake_lock.enabled owner=$safeHolder');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('call_wake_lock.enable_failed error=${e.runtimeType}');
      }
    }
  }

  Future<void> release(String holder) async {
    final safeHolder = holder.trim().isEmpty ? 'call' : holder.trim();
    _holders.remove(safeHolder);
    if (_holders.isNotEmpty) {
      debugPrint(
          'call_wake_lock.release_skipped_still_owned owner=$safeHolder');
      return;
    }

    try {
      await _channel.invokeMethod<void>(
        'setCallKeepScreenOn',
        <String, Object?>{'enabled': false, 'owner': safeHolder},
      );
      debugPrint('call_wake_lock.released owner=$safeHolder');
    } catch (e) {
      if (kDebugMode) {
        debugPrint('call_wake_lock.release_failed error=${e.runtimeType}');
      }
    }
  }
}
