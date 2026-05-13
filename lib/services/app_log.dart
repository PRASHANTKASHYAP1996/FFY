import 'package:flutter/foundation.dart';

class AppLog {
  const AppLog._();

  static final Map<String, DateTime> _lastLogAtByKey = <String, DateTime>{};
  static final Stopwatch _monotonicClock = Stopwatch()..start();
  static final String runTraceId =
      DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  static int _sequence = 0;

  static String safeId(String value) {
    final safe = value.trim();
    if (safe.isEmpty) return 'empty';
    if (safe.length <= 10) return safe;
    return '${safe.substring(0, 6)}...${safe.substring(safe.length - 4)}';
  }

  static String safeValue(String key, Object? value) {
    if (value == null) return 'null';
    final lowerKey = key.toLowerCase();
    final raw = value.toString();
    if (lowerKey.contains('token') ||
        lowerKey.contains('secret') ||
        lowerKey.contains('certificate') ||
        lowerKey.contains('password')) {
      return 'redacted';
    }
    if (lowerKey.contains('uid') ||
        lowerKey.contains('userid') ||
        lowerKey.contains('traceid') ||
        lowerKey.endsWith('id') ||
        lowerKey.contains('callid') ||
        lowerKey.contains('sessionid')) {
      return safeId(raw);
    }
    return _sanitizeValue(raw);
  }

  static String makeTraceId(String scope) {
    final safeScope = scope.trim().isEmpty
        ? 'trace'
        : scope.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$safeScope-$runTraceId-$now';
  }

  static Map<String, Object> cloudFunctionTracePayload(String traceId) {
    final now = DateTime.now();
    return <String, Object>{
      'clientTraceId': traceId.trim().isEmpty ? runTraceId : traceId.trim(),
      'clientRunTraceId': runTraceId,
      'clientDeviceEpochUs': now.microsecondsSinceEpoch,
      'clientMonoUs': _monotonicClock.elapsedMicroseconds,
    };
  }

  static void trace(
    String eventName, {
    String area = 'app',
    String? traceId,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final safeEvent = eventName.trim();
    if (safeEvent.isEmpty) return;

    final now = DateTime.now();
    final seq = ++_sequence;
    final effectiveTraceId = (traceId == null || traceId.trim().isEmpty)
        ? runTraceId
        : traceId.trim();
    final safeArea = area.trim().isEmpty ? 'app' : area.trim();
    final parts = <String>[
      'APP_TRACE',
      'event=$safeEvent',
      'area=$safeArea',
      'traceId=${safeValue('traceId', effectiveTraceId)}',
      'runTraceId=${safeValue('runTraceId', runTraceId)}',
      'seq=$seq',
      'deviceTime=${now.toIso8601String()}',
      'deviceEpochUs=${now.microsecondsSinceEpoch}',
      'monoUs=${_monotonicClock.elapsedMicroseconds}',
      'platform=${defaultTargetPlatform.name}',
      'release=$kReleaseMode',
    ];

    for (final entry in fields.entries) {
      if (entry.value == null) continue;
      final key = entry.key.trim();
      if (key.isEmpty) continue;
      parts.add('$key=${safeValue(key, entry.value)}');
    }

    debug(parts.join(' '));
  }

  static void marker(
    String name, {
    String? traceId,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    trace(
      name,
      area: 'TEST_MARKER',
      traceId: traceId,
      fields: fields,
    );
  }

  static void debug(String message) {
    debugPrint(message);
  }

  static void debugThrottled(
    String key,
    String message, {
    Duration interval = const Duration(seconds: 5),
  }) {
    final safeKey = key.trim();
    if (safeKey.isEmpty) {
      debug(message);
      return;
    }

    final now = DateTime.now();
    final lastAt = _lastLogAtByKey[safeKey];
    if (lastAt != null && now.difference(lastAt) < interval) return;

    _lastLogAtByKey[safeKey] = now;
    debug(message);

    if (_lastLogAtByKey.length > 96) {
      final cutoff = now.subtract(const Duration(minutes: 2));
      _lastLogAtByKey.removeWhere((_, value) => value.isBefore(cutoff));
    }
  }

  static String _sanitizeValue(String value) {
    return value
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_.:=@/+,-]'), '_');
  }
}
