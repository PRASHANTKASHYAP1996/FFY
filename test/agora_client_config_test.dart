import 'package:flutter_test/flutter_test.dart';
import 'package:friendify/core/constants/agora_client_config.dart';

void main() {
  test('release readiness requires FRIENDIFY_AGORA_APP_ID', () {
    final readiness = AgoraClientConfig.evaluateReadiness(
      releaseMode: true,
      releaseAppId: '',
      debugAppId: 'debug-app-id',
    );

    expect(readiness.isReady, isFalse);
    expect(
      readiness.missingRequirements,
      contains('FRIENDIFY_AGORA_APP_ID'),
    );
  });

  test('debug build can use FRIENDIFY_AGORA_TEST_APP_ID fallback', () {
    final readiness = AgoraClientConfig.evaluateReadiness(
      releaseMode: false,
      releaseAppId: '',
      debugAppId: 'debug-app-id',
    );

    expect(readiness.isReady, isTrue);
    expect(readiness.resolvedAppId, 'debug-app-id');
    expect(readiness.usingDebugFallback, isTrue);
  });

  test('release build ignores debug fallback app id', () {
    final readiness = AgoraClientConfig.evaluateReadiness(
      releaseMode: true,
      releaseAppId: '',
      debugAppId: 'debug-app-id',
    );

    expect(readiness.isReady, isFalse);
    expect(readiness.resolvedAppId, isEmpty);
  });

  test('placeholder Agora app ids are rejected', () {
    final releaseReadiness = AgoraClientConfig.evaluateReadiness(
      releaseMode: true,
      releaseAppId: 'YOUR_AGORA_APP_ID',
      debugAppId: '',
    );
    final debugReadiness = AgoraClientConfig.evaluateReadiness(
      releaseMode: false,
      releaseAppId: 'YOUR_APP_ID',
      debugAppId: 'placeholder',
    );

    expect(releaseReadiness.isReady, isFalse);
    expect(releaseReadiness.resolvedAppId, isEmpty);
    expect(releaseReadiness.clientAppIdStatus, 'PLACEHOLDER');
    expect(debugReadiness.isReady, isFalse);
    expect(debugReadiness.resolvedAppId, isEmpty);
    expect(debugReadiness.clientAppIdStatus, 'PLACEHOLDER');
  });
}
