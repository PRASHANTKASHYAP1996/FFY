import 'package:flutter/material.dart';

import 'models/app_user_model.dart';

enum UserSafetyAction {
  reportUser,
  blockUser,
  help,
}

const List<String> kUserSafetyReportReasons = <String>[
  'Harassment',
  'Unsafe content',
  'Scam or money request',
  'Payment issue',
  'Inappropriate behavior',
  'Threats or violence',
  'Other',
];

String userSafetyDisplayName(
  AppUserModel? user, {
  String fallback = 'this user',
}) {
  final name = (user?.safeDisplayName ?? '').trim();
  return name.isEmpty ? fallback : name;
}

bool userSafetyBlockApplies({
  required String myUid,
  required String otherUserId,
  required List<String> myBlockedUserIds,
  required List<String> otherBlockedUserIds,
}) {
  final safeMyUid = myUid.trim();
  final safeOtherUserId = otherUserId.trim();

  if (safeMyUid.isEmpty || safeOtherUserId.isEmpty) return false;

  final meBlockedOther = myBlockedUserIds.any(
    (id) => id.trim() == safeOtherUserId,
  );
  final otherBlockedMe = otherBlockedUserIds.any(
    (id) => id.trim() == safeMyUid,
  );

  return meBlockedOther || otherBlockedMe;
}

Future<String?> showUserSafetyReportReasonSheet(
  BuildContext context, {
  String title = 'Report user',
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 12),
            ...kUserSafetyReportReasons.map(
              (reason) => ListTile(
                leading: const Icon(Icons.flag_outlined),
                title: Text(reason),
                onTap: () => Navigator.pop(sheetContext, reason),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool> showBlockUserConfirmationDialog(
  BuildContext context, {
  required String userName,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('Block user'),
        content: Text(
          'Block $userName?\n\n'
          'Blocking disables chat and calling for this conversation.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Block user'),
          ),
        ],
      );
    },
  );

  return result == true;
}
