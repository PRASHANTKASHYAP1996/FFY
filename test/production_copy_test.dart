import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/legal_links.dart';

const _bannedProductionPhrases = <String>[
  'Before launch',
  'Current truth',
  'current build',
  'launch-phase',
  'Visible placeholder',
  'placeholder-only',
  'launch-prep build',
  'test-oriented',
  'manual/test',
  'test/manual',
  'internal ranking',
  'not live production',
  'founder/business/legal completion',
  'controlled placeholders',
  'not finalized',
  'payment phase note',
  'support and deletion note',
  'founder/business completion',
  'not finalized in this build',
  'May be unavailable',
  'May be busy',
  'Unavailable right now',
  'Check Firebase App Check',
  'Firestore rules/index deployment',
];

void main() {
  test('LegalLinks fallback copy stays neutral', () {
    final messages = <String>[
      LegalLinks.privacyPolicyMessage,
      LegalLinks.termsOfServiceMessage,
      LegalLinks.refundCancellationPolicyMessage,
      LegalLinks.supportMessage,
      LegalLinks.deleteAccountRequestMessage,
    ];

    for (final message in messages) {
      final normalized = message.toLowerCase();
      for (final phrase in _bannedProductionPhrases) {
        expect(
          normalized,
          isNot(contains(phrase.toLowerCase())),
          reason: 'Unexpected placeholder phrase in legal copy: $phrase',
        );
      }
    }
  });

  test(
      'Production UI widget source files do not contain banned placeholder text',
      () {
    final root = Directory.current.path;
    final files = <String>[
      '$root/lib/screens/auth_screen.dart',
      '$root/lib/screens/crisis_help_screen.dart',
      '$root/lib/screens/earnings_screen.dart',
      '$root/lib/screens/redesign/redesign_shell.dart',
      '$root/lib/screens/chat_conversation_screen.dart',
      '$root/lib/screens/listener_leaderboard_screen.dart',
      '$root/lib/screens/listener_profile_screen.dart',
      '$root/lib/screens/onboarding_screen.dart',
      '$root/lib/screens/profile_screen.dart',
      '$root/lib/screens/voice_call_screen.dart',
      '$root/lib/screens/wallet_details_screen.dart',
    ];

    for (final path in files) {
      final source = File(path).readAsStringSync();
      final normalized = source.toLowerCase();
      for (final phrase in _bannedProductionPhrases) {
        expect(
          normalized,
          isNot(contains(phrase.toLowerCase())),
          reason: 'Unexpected placeholder phrase "$phrase" in $path',
        );
      }
    }
  });
}
