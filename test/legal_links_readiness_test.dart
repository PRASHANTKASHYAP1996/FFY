import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/core/constants/legal_links.dart';

void main() {
  test('release readiness requires final legal and support configuration', () {
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
      contains(
        'Support URL or support email '
        '(FRIENDIFY_SUPPORT_URL or FRIENDIFY_SUPPORT_EMAIL)',
      ),
    );
  });

  test('placeholder legal values are rejected', () {
    final readiness = LegalLinks.evaluateReadiness(
      privacyPolicyUrl: 'YOUR_REAL_PRIVACY_URL',
      termsOfServiceUrl: '<https-url>',
      refundCancellationPolicyUrl: 'https-url',
      supportUrl: 'https://example.com/support',
      supportEmail: 'support-email',
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
  });
}
