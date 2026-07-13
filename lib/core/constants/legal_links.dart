import 'package:flutter/foundation.dart';

class LegalReleaseReadiness {
  const LegalReleaseReadiness({
    required this.missingRequirements,
  });

  final List<String> missingRequirements;

  bool get isReady => missingRequirements.isEmpty;
}

class LegalLinks {
  LegalLinks._();

  static final String privacyPolicyUrl =
      const String.fromEnvironment('FRIENDIFY_PRIVACY_URL').trim();
  static final String termsOfServiceUrl =
      const String.fromEnvironment('FRIENDIFY_TERMS_URL').trim();
  static final String refundCancellationPolicyUrl =
      const String.fromEnvironment('FRIENDIFY_REFUND_URL').trim();
  static final String supportUrl =
      const String.fromEnvironment('FRIENDIFY_SUPPORT_URL').trim();
  static final String supportEmail =
      const String.fromEnvironment('FRIENDIFY_SUPPORT_EMAIL').trim();

  static const String deleteAccountSupportPath =
      'Profile > Delete Account Request';

  static bool _looksLikePlaceholder(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    return normalized.contains('your_real_') ||
        normalized.contains('<') ||
        normalized.contains('>') ||
        normalized.contains('https-url') ||
        normalized.contains('support-email') ||
        normalized.contains('example.com');
  }

  static bool _looksLikeValidHttpsUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _looksLikePlaceholder(trimmed)) return false;
    final uri = Uri.tryParse(trimmed);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
  }

  static bool _looksLikeValidSupportEmail(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || _looksLikePlaceholder(trimmed)) return false;
    final parts = trimmed.split('@');
    if (parts.length != 2) return false;
    return parts[0].isNotEmpty && parts[1].contains('.');
  }

  static bool get hasPrivacyPolicy => _looksLikeValidHttpsUrl(privacyPolicyUrl);
  static bool get hasTermsOfService =>
      _looksLikeValidHttpsUrl(termsOfServiceUrl);
  static bool get hasRefundCancellationPolicy =>
      _looksLikeValidHttpsUrl(refundCancellationPolicyUrl);
  static bool get hasSupport =>
      _looksLikeValidHttpsUrl(supportUrl) ||
      _looksLikeValidSupportEmail(supportEmail);
  static bool get hasDeleteAccountSupportPath =>
      deleteAccountSupportPath.trim().isNotEmpty;

  static LegalReleaseReadiness evaluateReadiness({
    String? privacyPolicyUrl,
    String? termsOfServiceUrl,
    String? refundCancellationPolicyUrl,
    String? supportUrl,
    String? supportEmail,
    String? deleteAccountSupportPath,
  }) {
    final missing = <String>[];

    final privacy = (privacyPolicyUrl ?? LegalLinks.privacyPolicyUrl).trim();
    final terms = (termsOfServiceUrl ?? LegalLinks.termsOfServiceUrl).trim();
    final refund =
        (refundCancellationPolicyUrl ?? LegalLinks.refundCancellationPolicyUrl)
            .trim();
    final supportLink = (supportUrl ?? LegalLinks.supportUrl).trim();
    final supportMailbox = (supportEmail ?? LegalLinks.supportEmail).trim();
    final deletePath =
        (deleteAccountSupportPath ?? LegalLinks.deleteAccountSupportPath)
            .trim();

    if (!_looksLikeValidHttpsUrl(privacy)) {
      missing.add('Privacy Policy URL (FRIENDIFY_PRIVACY_URL)');
    }
    if (!_looksLikeValidHttpsUrl(terms)) {
      missing.add('Terms of Service URL (FRIENDIFY_TERMS_URL)');
    }
    if (!_looksLikeValidHttpsUrl(refund)) {
      missing.add(
        'Refund / Cancellation Policy URL (FRIENDIFY_REFUND_URL)',
      );
    }
    if (!_looksLikeValidHttpsUrl(supportLink) &&
        !_looksLikeValidSupportEmail(supportMailbox)) {
      missing.add(
        'Support URL or support email '
        '(FRIENDIFY_SUPPORT_URL or FRIENDIFY_SUPPORT_EMAIL)',
      );
    }
    if (deletePath.isEmpty) {
      missing.add('Account deletion support path');
    }

    return LegalReleaseReadiness(
      missingRequirements: List<String>.unmodifiable(missing),
    );
  }

  static LegalReleaseReadiness get currentReadiness => evaluateReadiness();

  static void assertReleaseReady({bool releaseMode = kReleaseMode}) {
    if (!releaseMode) return;

    final readiness = currentReadiness;
    if (readiness.isReady) return;

    final bulletList =
        readiness.missingRequirements.map((item) => '- $item').join('\n');

    throw StateError(
      'Release build blocked: legal/support configuration is incomplete.\n'
      '$bulletList',
    );
  }

  static String get privacyPolicyMessage => _policyMessage(
        label: 'Privacy Policy',
        url: privacyPolicyUrl,
      );

  static String get termsOfServiceMessage => _policyMessage(
        label: 'Terms of Service',
        url: termsOfServiceUrl,
      );

  static String get refundCancellationPolicyMessage => _policyMessage(
        label: 'Refund / Cancellation Policy',
        url: refundCancellationPolicyUrl,
      );

  static String get supportMessage {
    final validSupportUrl =
        _looksLikeValidHttpsUrl(supportUrl) ? supportUrl.trim() : '';
    final validSupportEmail =
        _looksLikeValidSupportEmail(supportEmail) ? supportEmail.trim() : '';

    if (validSupportUrl.isNotEmpty && validSupportEmail.isNotEmpty) {
      return 'Support is available at:\n$validSupportUrl\n\n'
          'Email: $validSupportEmail';
    }
    if (validSupportUrl.isNotEmpty) {
      return 'Support is available at:\n$validSupportUrl';
    }
    if (validSupportEmail.isNotEmpty) {
      return 'Support is available by email at $validSupportEmail.';
    }
    return 'Support is not configured for this build.';
  }

  static String get deleteAccountRequestMessage {
    if (!hasDeleteAccountSupportPath) {
      return 'Delete account support is not configured for this build.';
    }
    return 'Use $deleteAccountSupportPath to submit a delete account request. '
        'Requests are reviewed before the account is removed.';
  }

  static String _policyMessage({
    required String label,
    required String url,
  }) {
    final trimmedUrl = url.trim();
    if (!_looksLikeValidHttpsUrl(trimmedUrl)) {
      return '$label is not configured for this build.';
    }
    return 'Review the latest $label at:\n$trimmedUrl';
  }
}
