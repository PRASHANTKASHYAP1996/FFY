import 'package:flutter/material.dart';

import '../core/constants/legal_links.dart';
import '../core/theme/app_palette.dart';

enum LegalPolicyKind {
  terms,
  privacy,
  refund,
  communityGuidelines,
  accountDeletion,
}

class LegalPolicyScreen extends StatelessWidget {
  const LegalPolicyScreen({
    super.key,
    required this.kind,
  });

  final LegalPolicyKind kind;

  static const String lastUpdated = '25 Apr 2026';

  String get _title {
    switch (kind) {
      case LegalPolicyKind.terms:
        return 'Terms & Conditions';
      case LegalPolicyKind.privacy:
        return 'Privacy Policy';
      case LegalPolicyKind.refund:
        return 'Refund & Payment Policy';
      case LegalPolicyKind.communityGuidelines:
        return 'Community Guidelines';
      case LegalPolicyKind.accountDeletion:
        return 'Account Deletion';
    }
  }

  IconData get _icon {
    switch (kind) {
      case LegalPolicyKind.terms:
        return Icons.description_outlined;
      case LegalPolicyKind.privacy:
        return Icons.privacy_tip_outlined;
      case LegalPolicyKind.refund:
        return Icons.receipt_long_outlined;
      case LegalPolicyKind.communityGuidelines:
        return Icons.volunteer_activism_outlined;
      case LegalPolicyKind.accountDeletion:
        return Icons.delete_outline_rounded;
    }
  }

  List<_PolicySection> get _sections {
    switch (kind) {
      case LegalPolicyKind.terms:
        return [
          const _PolicySection(
            title: 'Use Friendify respectfully',
            body:
                'Friendify helps users connect for conversations, listening, and social support. You must not harass, threaten, impersonate, scam, exploit, or pressure another user.',
          ),
          const _PolicySection(
            title: 'Not emergency or professional advice',
            body:
                'Friendify is not an emergency service and is not a substitute for medical, legal, financial, psychiatric, or crisis care. Unless a user is separately verified and licensed, conversations should be treated as peer support only.',
          ),
          const _PolicySection(
            title: 'Wallet, calls, and moderation',
            body:
                'Credits, call access, withdrawals, and account access may be limited, reviewed, paused, or reversed when needed for safety, fraud prevention, payment review, or policy enforcement.',
          ),
          _PolicySection(
            title: 'External terms link',
            body: LegalLinks.termsOfServiceMessage,
          ),
        ];
      case LegalPolicyKind.privacy:
        return [
          const _PolicySection(
            title: 'Data categories',
            body:
                'Friendify may process account details, profile information, chat/call metadata, wallet/payment metadata, reports, device notification identifiers, support requests, and safety/moderation records.',
          ),
          const _PolicySection(
            title: 'Why data is used',
            body:
                'Data is used to run the app, show profiles, connect chats and calls, process wallet activity, send notifications, investigate abuse, provide support, and improve reliability.',
          ),
          const _PolicySection(
            title: 'Private content and safety',
            body:
                'Avoid sharing sensitive personal information in chats or calls. Reports and support requests may be reviewed by authorized admins for safety, fraud, or support handling.',
          ),
          _PolicySection(
            title: 'External privacy link',
            body: LegalLinks.privacyPolicyMessage,
          ),
        ];
      case LegalPolicyKind.refund:
        return [
          const _PolicySection(
            title: 'Credits and paid calls',
            body:
                'Wallet credits are used for eligible in-app calling features. A call may reserve credits before it starts, and final billing depends on the completed call and server-side settlement.',
          ),
          const _PolicySection(
            title: 'Refund/support path',
            body:
                'If a payment, call charge, failed call, duplicate charge, or wallet balance looks wrong, contact support with the amount, date, and a short description. Do not send payment secrets or full bank details.',
          ),
          const _PolicySection(
            title: 'Withdrawals',
            body:
                'Withdrawal requests may be manually reviewed. Some records may be retained for accounting, fraud prevention, safety, or legal reasons even after an account request is processed.',
          ),
          _PolicySection(
            title: 'External refund link',
            body: LegalLinks.refundCancellationPolicyMessage,
          ),
        ];
      case LegalPolicyKind.communityGuidelines:
        return const [
          _PolicySection(
            title: 'Be safe and respectful',
            body:
                'Do not harass, threaten, sexually pressure, discriminate, manipulate, shame, or exploit other users. Keep conversations consensual and respectful.',
          ),
          _PolicySection(
            title: 'No scams or unsafe requests',
            body:
                'Do not request money outside supported app flows, ask for sensitive documents, encourage self-harm, provide dangerous instructions, or impersonate professionals.',
          ),
          _PolicySection(
            title: 'Report and block',
            body:
                'Use Report user for abuse, scams, unsafe content, payment concerns, or inappropriate behavior. Use Block user when you do not want further chat or calls with someone.',
          ),
          _PolicySection(
            title: 'Crisis disclaimer',
            body:
                'Friendify is not emergency support. If you are in immediate danger or may harm yourself or someone else, stop using the app and contact local emergency services immediately.',
          ),
        ];
      case LegalPolicyKind.accountDeletion:
        return [
          const _PolicySection(
            title: 'How to request deletion',
            body:
                'Open Profile > Delete Account Request, add a short reason, and submit the request. The app records a request for review instead of deleting the account instantly from the device.',
          ),
          const _PolicySection(
            title: 'What may be retained',
            body:
                'Some records may be retained when needed for payment records, fraud prevention, safety reports, abuse investigations, legal compliance, dispute handling, or operational backups.',
          ),
          _PolicySection(
            title: 'Support contact',
            body: LegalLinks.supportMessage,
          ),
        ];
    }
  }

  Widget _sectionCard(_PolicySection section) {
    return Container(
      decoration: AppPalette.cardDecoration(radius: 18),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppPalette.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            section.body,
            style: const TextStyle(
              color: AppPalette.textSecondary,
              fontWeight: FontWeight.w600,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppPalette.pageBg,
      appBar: AppBar(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: AppPalette.textPrimary,
        surfaceTintColor: Colors.transparent,
        title: Text(_title),
      ),
      body: DecoratedBox(
        decoration: const BoxDecoration(color: AppPalette.pageBg),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              decoration: AppPalette.cardDecoration(radius: 18),
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                        color: AppPalette.blueTint,
                        borderRadius: BorderRadius.circular(14)),
                    child: Icon(_icon, color: AppPalette.blue),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Draft app policy',
                          style: TextStyle(
                            fontWeight: FontWeight.w900,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        SizedBox(height: 6),
                        Text(
                          'This in-app copy is a practical beta-readiness draft. Final public launch still needs founder/legal review.',
                          style: TextStyle(
                            color: AppPalette.textSecondary,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Last updated: $lastUpdated',
              style: TextStyle(
                color: AppPalette.textSecondary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            ..._sections.map(
              (section) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _sectionCard(section),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolicySection {
  const _PolicySection({
    required this.title,
    required this.body,
  });

  final String title;
  final String body;
}
