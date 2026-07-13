import 'package:flutter/foundation.dart';

class AgoraClientConfigReadiness {
  const AgoraClientConfigReadiness({
    required this.resolvedAppId,
    required this.missingRequirements,
    required this.usingDebugFallback,
    this.placeholderRequirements = const <String>[],
  });

  final String resolvedAppId;
  final List<String> missingRequirements;
  final bool usingDebugFallback;
  final List<String> placeholderRequirements;

  bool get isReady => resolvedAppId.isNotEmpty && missingRequirements.isEmpty;
  bool get hasPlaceholder => placeholderRequirements.isNotEmpty;
  String get clientAppIdStatus {
    if (isReady) return 'READY';
    if (hasPlaceholder) return 'PLACEHOLDER';
    return 'MISSING';
  }
}

class AgoraClientConfig {
  AgoraClientConfig._();

  static const String releaseAppId =
      String.fromEnvironment('FRIENDIFY_AGORA_APP_ID');
  static const String debugAppId =
      String.fromEnvironment('FRIENDIFY_AGORA_TEST_APP_ID');

  static bool _looksLikePlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return normalized == 'null' ||
        normalized == 'placeholder' ||
        normalized == 'your_agora_app_id' ||
        normalized == 'your_app_id' ||
        normalized.contains('your_real_') ||
        normalized.contains('placeholder') ||
        normalized.contains('<') ||
        normalized.contains('>') ||
        normalized.contains('matching-agora-app-id');
  }

  static String _sanitizeAppId(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _looksLikePlaceholder(trimmed)) {
      return '';
    }
    return trimmed;
  }

  static AgoraClientConfigReadiness evaluateReadiness({
    bool releaseMode = kReleaseMode,
    String? releaseAppId,
    String? debugAppId,
  }) {
    final rawReleaseAppId = releaseAppId ?? AgoraClientConfig.releaseAppId;
    final rawDebugAppId = debugAppId ?? AgoraClientConfig.debugAppId;
    final releasePlaceholder = _looksLikePlaceholder(rawReleaseAppId);
    final debugPlaceholder = _looksLikePlaceholder(rawDebugAppId);
    final configuredReleaseAppId = _sanitizeAppId(rawReleaseAppId);
    final configuredDebugAppId = _sanitizeAppId(rawDebugAppId);

    final usingDebugFallback = !releaseMode &&
        configuredReleaseAppId.isEmpty &&
        configuredDebugAppId.isNotEmpty;
    final resolvedAppId = configuredReleaseAppId.isNotEmpty
        ? configuredReleaseAppId
        : usingDebugFallback
            ? configuredDebugAppId
            : '';

    final missing = <String>[];
    final placeholders = <String>[];
    if (releasePlaceholder) {
      placeholders.add('FRIENDIFY_AGORA_APP_ID');
    }
    if (debugPlaceholder) {
      placeholders.add('FRIENDIFY_AGORA_TEST_APP_ID');
    }
    if (releaseMode) {
      if (configuredReleaseAppId.isEmpty) {
        missing.add('FRIENDIFY_AGORA_APP_ID');
      }
    } else if (resolvedAppId.isEmpty) {
      missing.add(
        'FRIENDIFY_AGORA_APP_ID or FRIENDIFY_AGORA_TEST_APP_ID',
      );
    }

    return AgoraClientConfigReadiness(
      resolvedAppId: resolvedAppId,
      missingRequirements: List<String>.unmodifiable(missing),
      usingDebugFallback: usingDebugFallback,
      placeholderRequirements: List<String>.unmodifiable(placeholders),
    );
  }

  static AgoraClientConfigReadiness get currentReadiness => evaluateReadiness();

  static String get resolvedAppId => currentReadiness.resolvedAppId;

  static void assertReleaseReady({bool releaseMode = kReleaseMode}) {
    if (!releaseMode) return;

    final readiness = evaluateReadiness(releaseMode: releaseMode);
    if (readiness.isReady) return;

    final bulletList =
        readiness.missingRequirements.map((item) => '- $item').join('\n');
    throw StateError(
      'Release build blocked: Agora client configuration is incomplete.\n'
      '$bulletList',
    );
  }

  static String missingConfigurationMessage({bool releaseMode = kReleaseMode}) {
    final readiness = evaluateReadiness(releaseMode: releaseMode);
    if (readiness.isReady) {
      return '';
    }

    if (releaseMode) {
      return 'Missing Agora client app ID for this release build.';
    }

    return 'Missing Agora client app ID for this build. '
        'Set FRIENDIFY_AGORA_APP_ID or FRIENDIFY_AGORA_TEST_APP_ID.';
  }

  static String get developerRunCommandMessage =>
      'Agora App ID missing. Run with '
      '--dart-define=FRIENDIFY_AGORA_APP_ID=YOUR_REAL_APP_ID.';
}
