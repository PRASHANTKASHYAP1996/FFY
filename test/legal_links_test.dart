import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/legal_links.dart';

void main() {
  test('legal readiness reports all required missing values', () {
    final readiness = LegalLinks.evaluateReadiness(
      privacyPolicyUrl: '',
      termsOfServiceUrl: '',
      refundCancellationPolicyUrl: '',
      supportUrl: '',
      supportEmail: '',
      deleteAccountSupportPath: '',
    );

    expect(readiness.isReady, isFalse);
    expect(
      readiness.missingRequirements,
      contains('Privacy Policy URL (FRIENDIFY_PRIVACY_URL)'),
    );
    expect(
      readiness.missingRequirements,
      contains('Terms of Service URL (FRIENDIFY_TERMS_URL)'),
    );
    expect(
      readiness.missingRequirements,
      contains(
        'Refund / Cancellation Policy URL (FRIENDIFY_REFUND_URL)',
      ),
    );
    expect(
      readiness.missingRequirements,
      contains(
        'Support URL or support email '
        '(FRIENDIFY_SUPPORT_URL or FRIENDIFY_SUPPORT_EMAIL)',
      ),
    );
    expect(
      readiness.missingRequirements,
      contains('Account deletion support path'),
    );
  });

  test('legal readiness accepts support email without support URL', () {
    final readiness = LegalLinks.evaluateReadiness(
      privacyPolicyUrl: 'https://friendify.app/privacy',
      termsOfServiceUrl: 'https://friendify.app/terms',
      refundCancellationPolicyUrl: 'https://friendify.app/refunds',
      supportUrl: '',
      supportEmail: 'support@friendify.app',
      deleteAccountSupportPath: 'Profile > Delete Account Request',
    );

    expect(readiness.isReady, isTrue);
    expect(readiness.missingRequirements, isEmpty);
  });

  test('legal readiness rejects non-HTTPS policy URLs', () {
    final readiness = LegalLinks.evaluateReadiness(
      privacyPolicyUrl: 'http://friendify.app/privacy',
      termsOfServiceUrl: 'https://friendify.app/terms',
      refundCancellationPolicyUrl: 'https://friendify.app/refunds',
      supportUrl: 'http://friendify.app/support',
      supportEmail: '',
      deleteAccountSupportPath: 'Profile > Delete Account Request',
    );

    expect(readiness.isReady, isFalse);
    expect(
      readiness.missingRequirements,
      contains('Privacy Policy URL (FRIENDIFY_PRIVACY_URL)'),
    );
    expect(
      readiness.missingRequirements,
      contains(
        'Support URL or support email '
        '(FRIENDIFY_SUPPORT_URL or FRIENDIFY_SUPPORT_EMAIL)',
      ),
    );
  });

  test('legal fallback copy stays neutral when links are missing', () {
    expect(
      LegalLinks.evaluateReadiness(
        privacyPolicyUrl: '',
        termsOfServiceUrl: '',
        refundCancellationPolicyUrl: '',
        supportUrl: '',
        supportEmail: '',
        deleteAccountSupportPath: 'Profile > Delete Account Request',
      ).isReady,
      isFalse,
    );

    expect(
      LegalLinks.privacyPolicyMessage,
      anyOf(
        equals('Privacy Policy is not configured for this build.'),
        startsWith('Review the latest Privacy Policy at:'),
      ),
    );
    expect(
      LegalLinks.supportMessage,
      anyOf(
        equals('Support is not configured for this build.'),
        startsWith('Support is available'),
      ),
    );
    expect(
      LegalLinks.deleteAccountRequestMessage,
      contains('Delete Account Request'),
    );
  });
}
