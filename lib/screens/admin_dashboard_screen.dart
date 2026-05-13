import 'package:flutter/material.dart';

import '../repositories/admin_repository.dart';
import '../services/app_log.dart';
import '../shared/models/admin_dashboard_model.dart';

class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  final AdminRepository _repository = AdminRepository.instance;

  late Future<AdminDashboardModel> _future;
  final Set<String> _busyWithdrawalIds = <String>{};
  final Set<String> _busyUserIds = <String>{};
  final Set<String> _busyReportIds = <String>{};
  final Set<String> _busyAccountDeletionRequestIds = <String>{};
  String _withdrawalDrilldownKey = '';
  String _adminActionFilterKey = '';
  String _paymentOrderFilterKey = '';
  bool _refreshingServerCache = false;
  bool _backfillingPublicUsers = false;
  bool _backfillingFollowersCount = false;

  @override
  void initState() {
    super.initState();
    _future = _repository.loadDashboard();
  }

  Future<void> _reload({bool forceRefresh = false}) async {
    setState(() {
      _future = _repository.loadDashboard(forceRefresh: forceRefresh);
    });
  }

  Future<void> _refreshServerCache() async {
    if (_refreshingServerCache) return;

    setState(() {
      _refreshingServerCache = true;
    });

    try {
      await _repository.refreshDashboardCache();
      await _reload(forceRefresh: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Admin dashboard cache refreshed.')),
      );
    } catch (error) {
      debugPrint(
        'admin.dashboard.cache_refresh_failed ${error.runtimeType}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not refresh server cache. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _refreshingServerCache = false;
        });
      } else {
        _refreshingServerCache = false;
      }
    }
  }

  int _resultCount(Map<String, dynamic> result, String key) {
    final value = result[key];
    if (value is int) return value;
    if (value is num) return value.floor();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  Future<void> _backfillPublicUsers() async {
    if (_backfillingPublicUsers) return;

    setState(() {
      _backfillingPublicUsers = true;
    });

    try {
      final result = await _repository.backfillPublicUsers();
      await _reload(forceRefresh: true);
      if (!mounted) return;
      final processed = _resultCount(result, 'processed');
      final deleted = _resultCount(result, 'deleted');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Public users backfilled. Processed $processed, deleted $deleted.',
          ),
        ),
      );
    } catch (error) {
      debugPrint('admin.public_users_backfill_failed ${error.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not backfill public users. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _backfillingPublicUsers = false;
        });
      } else {
        _backfillingPublicUsers = false;
      }
    }
  }

  Future<void> _backfillFollowersCount() async {
    if (_backfillingFollowersCount) return;

    setState(() {
      _backfillingFollowersCount = true;
    });

    try {
      final result = await _repository.backfillFollowersCount();
      await _reload(forceRefresh: true);
      if (!mounted) return;
      final processed = _resultCount(result, 'processed');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Follower counts backfilled for $processed users.'),
        ),
      );
    } catch (error) {
      debugPrint('admin.followers_backfill_failed ${error.runtimeType}');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Could not backfill follower counts. Please try again.'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _backfillingFollowersCount = false;
        });
      } else {
        _backfillingFollowersCount = false;
      }
    }
  }

  String _dateLabel(DateTime? dt) {
    if (dt == null) return 'Unknown';

    const months = <String>[
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    final hour24 = dt.hour;
    final minute = dt.minute.toString().padLeft(2, '0');
    final amPm = hour24 >= 12 ? 'PM' : 'AM';
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;

    return '${dt.day} ${months[dt.month - 1]} ${dt.year}, $hour12:$minute $amPm';
  }

  bool _looksLikePermissionError(Object error) {
    final text = error.toString().toLowerCase();
    return text.contains('permission-denied') ||
        text.contains('permission denied') ||
        text.contains('admin access required') ||
        text.contains('unauthenticated');
  }

  void _showAdminActionFailure(
    String message,
    Object error,
    StackTrace _,
  ) {
    debugPrint('$message: ${error.runtimeType}');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _approveWithdrawal(AdminWithdrawalItem item) async {
    if (_busyWithdrawalIds.contains(item.id)) return;

    final referenceController = TextEditingController();
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Approve withdrawal?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Attach the payout reference after confirming the external transfer.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Payout reference',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Admin note',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Approve'),
              ),
            ],
          ),
        ) ??
        false;
    final paymentReference = referenceController.text.trim();
    final adminNote = noteController.text.trim();
    referenceController.dispose();
    noteController.dispose();

    if (!mounted || !confirmed) return;

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.approveWithdrawal(
        item.id,
        adminNote: adminNote,
        paymentReference: paymentReference,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal approved.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not approve this withdrawal. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyWithdrawalIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _rejectWithdrawal(AdminWithdrawalItem item) async {
    if (_busyWithdrawalIds.contains(item.id)) return;

    final reasonController = TextEditingController();
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Reject withdrawal?'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Record a clear reason for support, audit review, and the user-facing withdrawal status.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: reasonController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Rejection reason',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Reject'),
              ),
            ],
          ),
        ) ??
        false;
    final reason = reasonController.text.trim();
    reasonController.dispose();

    if (!mounted || !confirmed) return;

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.rejectWithdrawal(
        item.id,
        reason: reason.isEmpty ? 'Rejected by admin' : reason,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal rejected.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not reject this withdrawal. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyWithdrawalIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _updateWithdrawalPayoutProof(AdminWithdrawalItem item) async {
    if (_busyWithdrawalIds.contains(item.id)) return;

    final referenceController = TextEditingController(
      text: item.paymentReference,
    );
    final noteController = TextEditingController();
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Add payout proof'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Attach the external payout reference for this approved withdrawal.',
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Payout reference',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: noteController,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Admin note',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Save proof'),
              ),
            ],
          ),
        ) ??
        false;
    final paymentReference = referenceController.text.trim();
    final adminNote = noteController.text.trim();
    referenceController.dispose();
    noteController.dispose();

    if (!mounted || !confirmed || paymentReference.isEmpty) return;

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.updateWithdrawalPayoutProof(
        item.id,
        paymentReference: paymentReference,
        adminNote: adminNote,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Payout proof saved.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not save payout proof. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyWithdrawalIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _repairWithdrawalLedgerProof(AdminWithdrawalItem item) async {
    if (_busyWithdrawalIds.contains(item.id)) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Repair ledger proof?'),
            content: const Text(
              'This will verify the approved withdrawal ledger record and update the request with settlement proof.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Repair'),
              ),
            ],
          ),
        ) ??
        false;

    if (!mounted || !confirmed) return;

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.repairWithdrawalLedgerProof(
        item.id,
        paymentReference: item.paymentReference,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ledger proof repaired.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not repair ledger proof. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyWithdrawalIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _reviewAccountDeletionRequest(
    AdminAccountDeletionRequestItem item, {
    required String outcome,
  }) async {
    if (_busyAccountDeletionRequestIds.contains(item.id)) return;

    final completed = outcome == 'completed';
    final noteController = TextEditingController();
    var retentionPolicyApplied = completed;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => StatefulBuilder(
            builder: (dialogContext, setDialogState) => AlertDialog(
              title: Text(
                completed
                    ? 'Mark delete request complete?'
                    : 'Reject delete request?',
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    completed
                        ? 'Use this only after the manual account deletion and required retention review are complete.'
                        : 'Use this when the request cannot be processed and support/admin has documented the reason.',
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Admin note',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: retentionPolicyApplied,
                    onChanged: (value) {
                      setDialogState(() {
                        retentionPolicyApplied = value == true;
                      });
                    },
                    title: const Text('Retention policy applied'),
                    controlAffinity: ListTileControlAffinity.leading,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  child: Text(completed ? 'Mark complete' : 'Reject'),
                ),
              ],
            ),
          ),
        ) ??
        false;

    final note = noteController.text.trim();
    noteController.dispose();

    if (!mounted || !confirmed) return;

    setState(() {
      _busyAccountDeletionRequestIds.add(item.id);
    });

    try {
      await _repository.reviewAccountDeletionRequest(
        item.id,
        outcome: outcome,
        note: note,
        retentionPolicyApplied: retentionPolicyApplied,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            completed
                ? 'Delete-account request marked complete.'
                : 'Delete-account request rejected.',
          ),
        ),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not update this delete-account request. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyAccountDeletionRequestIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _blockUser(AdminUserItem item) async {
    if (_busyUserIds.contains(item.id)) return;

    setState(() {
      _busyUserIds.add(item.id);
    });

    try {
      await _repository.blockUser(item.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User blocked by admin.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not block this user. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyUserIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _unblockUser(AdminUserItem item) async {
    if (_busyUserIds.contains(item.id)) return;

    setState(() {
      _busyUserIds.add(item.id);
    });

    try {
      await _repository.unblockUser(item.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('User unblocked by admin.')),
      );
      await _reload(forceRefresh: true);
    } catch (e, st) {
      _showAdminActionFailure(
        'Could not unblock this user. Please try again.',
        e,
        st,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyUserIds.remove(item.id);
        });
      }
    }
  }

  Future<void> _dismissReport(AdminReportItem item) async {
    if (_busyReportIds.contains(item.id)) return;
    setState(() => _busyReportIds.add(item.id));
    try {
      await _repository.resolveReport(item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Report dismissed.')),
      );
      await _reload(forceRefresh: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not dismiss this report.')),
      );
    } finally {
      if (mounted) setState(() => _busyReportIds.remove(item.id));
    }
  }

  Future<void> _deleteReportedContent(AdminReportItem item) async {
    if (_busyReportIds.contains(item.id)) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Delete reported content?'),
            content: Text(
              item.type == 'social_comment'
                  ? 'This will delete the reported comment and mark the report reviewed.'
                  : 'This will delete the reported post and mark the report reviewed.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!mounted || !confirmed) return;

    setState(() => _busyReportIds.add(item.id));
    try {
      await _repository.deleteReportedContent(item.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reported content deleted.')),
      );
      await _reload(forceRefresh: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not delete reported content.')),
      );
    } finally {
      if (mounted) setState(() => _busyReportIds.remove(item.id));
    }
  }

  Future<void> _blockReportedUser(AdminReportItem item) async {
    final userId = item.reportedUserId.trim();
    if (userId.isEmpty || _busyReportIds.contains(item.id)) return;
    setState(() => _busyReportIds.add(item.id));
    try {
      await _repository.blockUser(
        userId,
        reason: 'Blocked from report ${item.id}',
      );
      await _repository.resolveReport(
        item.id,
        resolution: 'reported_user_blocked',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reported user blocked.')),
      );
      await _reload(forceRefresh: true);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not block reported user.')),
      );
    } finally {
      if (mounted) setState(() => _busyReportIds.remove(item.id));
    }
  }

  Widget _sectionHeader(
    String title, {
    String? subtitle,
    Widget? trailing,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF111827),
                ),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (trailing != null) trailing,
      ],
    );
  }

  Widget _sectionCard({
    required String title,
    String? subtitle,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              title,
              subtitle: subtitle,
              trailing: trailing,
            ),
            const SizedBox(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _metricCard({
    required String label,
    required String value,
    Color? color,
    IconData? icon,
    bool highlight = false,
    String? subtitle,
  }) {
    final safeColor = color ?? const Color(0xFF4F46E5);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: highlight
            ? safeColor.withValues(alpha: 0.12)
            : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlight
              ? safeColor.withValues(alpha: 0.24)
              : const Color(0xFFE5E7EB),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight <= 118;
          final iconBoxSize = compact ? 30.0 : 36.0;
          final iconSize = compact ? 16.0 : 18.0;
          final valueFontSize =
              highlight ? (compact ? 20.0 : 24.0) : (compact ? 17.0 : 20.0);
          final gapAfterIcon = compact ? 8.0 : 10.0;
          final gapAfterValue = compact ? 4.0 : 6.0;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Container(
                  width: iconBoxSize,
                  height: iconBoxSize,
                  decoration: BoxDecoration(
                    color: safeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: safeColor, size: iconSize),
                ),
                SizedBox(height: gapAfterIcon),
              ],
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  style: TextStyle(
                    fontSize: valueFontSize,
                    fontWeight: FontWeight.w900,
                    color: highlight ? safeColor : const Color(0xFF111827),
                  ),
                ),
              ),
              SizedBox(height: gapAfterValue),
              Text(
                label,
                maxLines: compact ? 2 : 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827),
                  height: 1.15,
                ),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: compact ? 2 : 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _statusChip(String status) {
    final safe = status.trim().toLowerCase();

    Color color;
    switch (safe) {
      case 'pending':
      case 'created':
      case 'open':
        color = const Color(0xFFD97706);
        break;
      case 'approved':
      case 'verified':
      case 'paid':
      case 'captured':
      case 'completed':
      case 'active':
      case 'reviewed':
      case 'resolved':
      case 'closed':
        color = const Color(0xFF15803D);
        break;
      case 'rejected':
      case 'failed':
      case 'cancelled':
      case 'blocked':
        color = const Color(0xFFDC2626);
        break;
      default:
        color = const Color(0xFF6B7280);
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: 0.24),
        ),
      ),
      child: Text(
        status.isEmpty ? 'unknown' : status,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _pill(
    String text, {
    Color bg = const Color(0xFFF3F4F8),
    Color fg = const Color(0xFF374151),
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  String _financeWarningLabel(String key) {
    switch (key) {
      case 'approvedWithdrawalsMissingPaymentReference':
        return 'Missing payout ref';
      case 'approvedWithdrawalsMissingLedgerSettlement':
        return 'Missing ledger proof';
      case 'verifiedPaymentVsTopupLedger':
        return 'Payment ledger delta';
      case 'callBilledVsChargeLedger':
        return 'Call charge delta';
      case 'callPayoutVsEarningLedger':
        return 'Call payout delta';
      case 'approvedWithdrawalVsLedger':
        return 'Withdrawal ledger delta';
      case 'pendingWithdrawalHoldsVsUserLiability':
        return 'Pending hold delta';
      case 'activeCallReserveVsUserLiability':
        return 'Call reserve delta';
      case 'nonCompletedWalletTransactions':
        return 'Open wallet tx';
      default:
        return key.isEmpty ? 'All withdrawals' : key;
    }
  }

  bool _warningCanFilterWithdrawals(String key) {
    return key == 'approvedWithdrawalsMissingPaymentReference' ||
        key == 'approvedWithdrawalsMissingLedgerSettlement';
  }

  bool _withdrawalMatchesDrilldown(AdminWithdrawalItem item, String key) {
    final status = item.status.trim().toLowerCase();
    if (key == 'approvedWithdrawalsMissingPaymentReference') {
      return status == 'approved' && item.paymentReference.trim().isEmpty;
    }
    if (key == 'approvedWithdrawalsMissingLedgerSettlement') {
      return status == 'approved' &&
          (!item.settledInLedger || item.settlementLedgerTxId.trim().isEmpty);
    }
    return true;
  }

  List<AdminWithdrawalItem> _withdrawalsForDrilldown(
    AdminDashboardModel data,
  ) {
    if (_withdrawalDrilldownKey ==
        'approvedWithdrawalsMissingPaymentReference') {
      if (data.withdrawalsMissingPaymentReference.isNotEmpty) {
        return data.withdrawalsMissingPaymentReference;
      }
    } else if (_withdrawalDrilldownKey ==
        'approvedWithdrawalsMissingLedgerSettlement') {
      if (data.withdrawalsMissingLedgerSettlement.isNotEmpty) {
        return data.withdrawalsMissingLedgerSettlement;
      }
    } else {
      return data.latestPendingWithdrawals;
    }

    return data.latestPendingWithdrawals
        .where((item) =>
            _withdrawalMatchesDrilldown(item, _withdrawalDrilldownKey))
        .toList();
  }

  int _financeWarningTotal(AdminFinanceReconciliation finance, String key) {
    for (final warning in finance.warnings) {
      if (warning.key != key) continue;
      if (warning.count != 0) return warning.count;
      if (warning.delta != 0) return warning.delta.abs();
    }
    return 0;
  }

  Widget _financeWarningChips(AdminFinanceReconciliation finance) {
    if (finance.warnings.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: finance.warnings.map((warning) {
        final canFilter = _warningCanFilterWithdrawals(warning.key);
        final selected = _withdrawalDrilldownKey == warning.key;
        final value = warning.count != 0 ? warning.count : warning.delta;
        final label = value == 0
            ? _financeWarningLabel(warning.key)
            : '${_financeWarningLabel(warning.key)}: $value';

        return ChoiceChip(
          selected: selected,
          onSelected: canFilter
              ? (_) {
                  setState(() {
                    _withdrawalDrilldownKey = selected ? '' : warning.key;
                  });
                }
              : null,
          avatar: Icon(
            canFilter ? Icons.filter_alt_rounded : Icons.warning_rounded,
            size: 16,
            color: selected
                ? const Color(0xFFFFFFFF)
                : canFilter
                    ? const Color(0xFFB45309)
                    : const Color(0xFF6B7280),
          ),
          label: Text(label),
          labelStyle: TextStyle(
            color: selected
                ? const Color(0xFFFFFFFF)
                : canFilter
                    ? const Color(0xFF92400E)
                    : const Color(0xFF374151),
            fontWeight: FontWeight.w800,
          ),
          selectedColor: const Color(0xFFB45309),
          backgroundColor:
              canFilter ? const Color(0xFFFFFBEB) : const Color(0xFFF3F4F6),
          disabledColor: const Color(0xFFF3F4F6),
          side: BorderSide(
            color:
                canFilter ? const Color(0xFFF59E0B) : const Color(0xFFE5E7EB),
          ),
        );
      }).toList(),
    );
  }

  String _paymentOrderStatusKey(AdminPaymentOrderItem item) {
    final serverKey = item.statusCategory.trim();
    if (serverKey.isNotEmpty) return serverKey;

    final status = item.status.trim().toLowerCase();
    if (status == 'verified' || status == 'paid' || status == 'captured') {
      return 'verified';
    }
    if (status == 'pending' || status == 'created') {
      return 'pending';
    }
    if (status == 'failed' || status == 'cancelled') {
      return 'failed';
    }
    return 'other';
  }

  String _paymentOrderFilterLabel(String key) {
    switch (key) {
      case 'verified':
        return 'Verified';
      case 'pending':
        return 'Pending';
      case 'failed':
        return 'Failed';
      case 'other':
        return 'Other';
      default:
        return key.isEmpty ? 'All orders' : key;
    }
  }

  List<String> _paymentOrderFilterKeys(Map<String, int> counts) {
    const preferred = <String>['verified', 'pending', 'failed', 'other'];
    final keys = preferred.where((key) => (counts[key] ?? 0) > 0).toList();
    final extras = counts.keys
        .where((key) => key.trim().isNotEmpty && !preferred.contains(key))
        .where((key) => (counts[key] ?? 0) > 0)
        .toList()
      ..sort();
    return <String>[...keys, ...extras];
  }

  List<AdminPaymentOrderItem> _filteredPaymentOrders(
    AdminDashboardModel data,
  ) {
    final items = data.latestPaymentOrders;
    if (_paymentOrderFilterKey.isEmpty) return items;
    final serverItems = data.paymentOrdersByStatus[_paymentOrderFilterKey];
    if (serverItems != null && serverItems.isNotEmpty) return serverItems;
    return items
        .where((item) => _paymentOrderStatusKey(item) == _paymentOrderFilterKey)
        .toList();
  }

  Widget _paymentOrderFilterChips(
    List<AdminPaymentOrderItem> items, {
    Map<String, int> serverCounts = const <String, int>{},
  }) {
    final counts = <String, int>{};
    for (final item in items) {
      final key = _paymentOrderStatusKey(item);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    serverCounts.forEach((key, value) {
      final safeKey = key.trim();
      if (safeKey.isEmpty || value <= 0) return;
      counts[safeKey] = value;
    });
    final keys = _paymentOrderFilterKeys(counts);
    if (keys.isEmpty) return const SizedBox.shrink();

    final totalCount = serverCounts.isEmpty
        ? items.length
        : serverCounts.values.fold<int>(0, (sum, value) => sum + value);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          selected: _paymentOrderFilterKey.isEmpty,
          onSelected: (_) => setState(() => _paymentOrderFilterKey = ''),
          avatar: Icon(
            Icons.all_inclusive_rounded,
            size: 16,
            color: _paymentOrderFilterKey.isEmpty
                ? const Color(0xFFFFFFFF)
                : const Color(0xFF374151),
          ),
          label: Text('All: $totalCount'),
          labelStyle: TextStyle(
            color: _paymentOrderFilterKey.isEmpty
                ? const Color(0xFFFFFFFF)
                : const Color(0xFF374151),
            fontWeight: FontWeight.w800,
          ),
          selectedColor: const Color(0xFF374151),
          backgroundColor: const Color(0xFFF3F4F6),
          side: BorderSide(
            color: const Color(0xFF374151).withValues(alpha: 0.24),
          ),
        ),
        ...keys.map((key) {
          final selected = _paymentOrderFilterKey == key;
          return ChoiceChip(
            selected: selected,
            onSelected: (_) {
              setState(() => _paymentOrderFilterKey = selected ? '' : key);
            },
            avatar: Icon(
              Icons.receipt_long_rounded,
              size: 16,
              color:
                  selected ? const Color(0xFFFFFFFF) : const Color(0xFFD97706),
            ),
            label: Text('${_paymentOrderFilterLabel(key)}: ${counts[key]}'),
            labelStyle: TextStyle(
              color:
                  selected ? const Color(0xFFFFFFFF) : const Color(0xFF92400E),
              fontWeight: FontWeight.w800,
            ),
            selectedColor: const Color(0xFFD97706),
            backgroundColor: const Color(0xFFFFFBEB),
            side: BorderSide(
              color: const Color(0xFFD97706).withValues(alpha: 0.24),
            ),
          );
        }),
      ],
    );
  }

  Widget _reportCard(AdminReportItem item) {
    final reason = item.reason.isEmpty ? 'No reason' : item.reason;
    final reporter =
        item.reporterId.isEmpty ? 'Unknown' : AppLog.safeId(item.reporterId);
    final reportedUser = item.reportedUserId.isEmpty
        ? 'Unknown'
        : AppLog.safeId(item.reportedUserId);
    final callId = item.callId.isEmpty ? 'Unknown' : AppLog.safeId(item.callId);
    final contentId = item.type == 'social_comment'
        ? 'Post ${AppLog.safeId(item.postId)} / Comment ${AppLog.safeId(item.commentId)}'
        : item.type == 'social_post'
            ? 'Post ${AppLog.safeId(item.postId)}'
            : 'Call $callId';
    final isBusy = _busyReportIds.contains(item.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFFEF2F2),
            child: Icon(
              Icons.flag_rounded,
              color: Color(0xFFDC2626),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        reason,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(item.status),
                  ],
                ),
                if (item.commentText.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.commentText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w700,
                      height: 1.28,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  'Type: ${item.type} - Reports: ${item.reportCount <= 0 ? 1 : item.reportCount}',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Reporter: $reporter - Reported user: $reportedUser',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  contentId,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.reviewedAt == null
                      ? _dateLabel(item.createdAt)
                      : 'Reviewed: ${_dateLabel(item.reviewedAt)}',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.resolution.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Resolution: ${item.resolution}',
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                if (item.isOpen) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: isBusy ? null : () => _dismissReport(item),
                        child: Text(isBusy ? 'Working...' : 'Dismiss'),
                      ),
                      if (item.canDeleteReportedContent)
                        FilledButton(
                          onPressed: isBusy
                              ? null
                              : () => _deleteReportedContent(item),
                          child: const Text('Delete content'),
                        ),
                      if (item.reportedUserId.isNotEmpty)
                        OutlinedButton(
                          onPressed:
                              isBusy ? null : () => _blockReportedUser(item),
                          child: const Text('Block user'),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _withdrawalCard(AdminWithdrawalItem item) {
    final userId = item.userId.isEmpty ? 'Unknown' : AppLog.safeId(item.userId);
    final status = item.status.trim().toLowerCase();
    final isPending = status == 'pending';
    final needsPayoutProof =
        status == 'approved' && item.paymentReference.trim().isEmpty;
    final needsLedgerProof = status == 'approved' &&
        (!item.settledInLedger || item.settlementLedgerTxId.trim().isEmpty);
    final isBusy = _busyWithdrawalIds.contains(item.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFECFDF3),
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  color: Color(0xFF15803D),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rs ${item.amount}',
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'User: $userId',
                      style: const TextStyle(
                        color: Color(0xFF374151),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _dateLabel(item.requestedAt),
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (item.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Note: ${item.note}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (item.adminNote.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Admin note: ${item.adminNote}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (item.statusReason.isNotEmpty &&
                        item.statusReason != item.adminNote) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Reason: ${item.statusReason}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (item.paymentReference.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Payout ref: ${item.paymentReference}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (item.settlementLedgerTxId.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Ledger: ${AppLog.safeId(item.settlementLedgerTxId)}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ] else if (item.settledInLedger) ...[
                      const SizedBox(height: 4),
                      const Text(
                        'Ledger: settled',
                        style: TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _statusChip(item.status),
            ],
          ),
          if (isPending) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: isBusy ? null : () => _approveWithdrawal(item),
                    child: Text(isBusy ? 'Working...' : 'Approve'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: isBusy ? null : () => _rejectWithdrawal(item),
                    child: const Text('Reject'),
                  ),
                ),
              ],
            ),
          ] else if (needsPayoutProof || needsLedgerProof) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                if (needsPayoutProof)
                  OutlinedButton(
                    onPressed: isBusy
                        ? null
                        : () => _updateWithdrawalPayoutProof(item),
                    child: Text(isBusy ? 'Working...' : 'Add payout proof'),
                  ),
                if (needsLedgerProof)
                  OutlinedButton(
                    onPressed: isBusy
                        ? null
                        : () => _repairWithdrawalLedgerProof(item),
                    child: Text(isBusy ? 'Working...' : 'Repair ledger proof'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _accountDeletionRequestCard(AdminAccountDeletionRequestItem item) {
    final userId = item.userId.isEmpty ? 'Unknown' : AppLog.safeId(item.userId);
    final displayName =
        item.displayName.isEmpty ? 'Unnamed user' : item.displayName;
    final email = item.email.isEmpty ? 'No email on request' : item.email;
    final statusDetail = item.outcome.isNotEmpty
        ? '${item.status} - ${item.outcome}'
        : item.status;
    final isBusy = _busyAccountDeletionRequestIds.contains(item.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFFFF1F2),
            child: Icon(
              Icons.person_remove_alt_1_rounded,
              color: Color(0xFFE11D48),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        displayName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(statusDetail),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'User: $userId',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  email,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Requested: ${_dateLabel(item.requestedAt)}',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.reason.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Reason: ${item.reason}',
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (item.note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Note: ${item.note}',
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (item.adminNote.isNotEmpty ||
                    item.reviewedBy.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Admin: ${item.adminNote.isEmpty ? 'No note' : item.adminNote} ${item.reviewedBy.isEmpty ? '' : '(by ${AppLog.safeId(item.reviewedBy)})'}',
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  item.retentionPolicyApplied
                      ? 'Retention policy marked applied.'
                      : 'Retention policy not marked applied.',
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (item.isPending) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton(
                        onPressed: isBusy
                            ? null
                            : () => _reviewAccountDeletionRequest(
                                  item,
                                  outcome: 'completed',
                                ),
                        child: Text(isBusy ? 'Working...' : 'Mark complete'),
                      ),
                      OutlinedButton(
                        onPressed: isBusy
                            ? null
                            : () => _reviewAccountDeletionRequest(
                                  item,
                                  outcome: 'rejected',
                                ),
                        child: const Text('Reject'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _adminActionTitle(AdminActionItem item) {
    final safe = item.actionType.trim();
    if (safe.isEmpty) return 'Admin action';

    final words = safe
        .replaceAll('_', ' ')
        .split(RegExp(r'\s+'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (words.isEmpty) return 'Admin action';

    return words
        .map((word) => word.length == 1
            ? word.toUpperCase()
            : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  String _adminActionCategory(AdminActionItem item) {
    final category = item.actionCategory.trim();
    if (category.isNotEmpty) return category;

    final safe = item.actionType.trim().toLowerCase();
    if (safe == 'admin_dashboard_cache_refreshed') return 'cache';
    if (safe.contains('withdrawal') || safe.contains('payout')) {
      return 'finance';
    }
    if (safe.contains('report') || safe.contains('moderation')) {
      return 'moderation';
    }
    if (safe.contains('account_deletion')) return 'accountDeletion';
    if (safe.contains('user_blocked') || safe.contains('user_unblocked')) {
      return 'userAccess';
    }
    return 'other';
  }

  String _adminActionFilterLabel(String key) {
    switch (key) {
      case 'finance':
        return 'Finance';
      case 'moderation':
        return 'Moderation';
      case 'accountDeletion':
        return 'Account deletion';
      case 'cache':
        return 'Cache';
      case 'userAccess':
        return 'User access';
      case 'other':
        return 'Other';
      default:
        if (key.trim().isEmpty) return 'All';
        final words = key
            .replaceAll('_', ' ')
            .split(RegExp(r'(?=[A-Z])|\s+'))
            .where((part) => part.trim().isNotEmpty)
            .toList();
        if (words.isEmpty) return key;
        return words
            .map((word) => word.length == 1
                ? word.toUpperCase()
                : '${word[0].toUpperCase()}${word.substring(1).toLowerCase()}')
            .join(' ');
    }
  }

  List<String> _adminActionFilterKeys(Map<String, int> counts) {
    const preferred = <String>[
      'finance',
      'moderation',
      'accountDeletion',
      'cache',
      'userAccess',
      'other',
    ];
    final keys = preferred.where((key) => (counts[key] ?? 0) > 0).toList();
    final extras = counts.keys
        .where((key) => key.trim().isNotEmpty && !preferred.contains(key))
        .where((key) => (counts[key] ?? 0) > 0)
        .toList()
      ..sort();
    return <String>[...keys, ...extras];
  }

  Color _adminActionCategoryBg(String key) {
    switch (key) {
      case 'finance':
        return const Color(0xFFECFDF5);
      case 'moderation':
        return const Color(0xFFFFF7ED);
      case 'accountDeletion':
        return const Color(0xFFFFF1F2);
      case 'cache':
        return const Color(0xFFEFF6FF);
      case 'userAccess':
        return const Color(0xFFEEF2FF);
      default:
        return const Color(0xFFF3F4F6);
    }
  }

  Color _adminActionCategoryFg(String key) {
    switch (key) {
      case 'finance':
        return const Color(0xFF047857);
      case 'moderation':
        return const Color(0xFFC2410C);
      case 'accountDeletion':
        return const Color(0xFFE11D48);
      case 'cache':
        return const Color(0xFF2563EB);
      case 'userAccess':
        return const Color(0xFF4F46E5);
      default:
        return const Color(0xFF374151);
    }
  }

  IconData _adminActionCategoryIcon(String key) {
    switch (key) {
      case 'finance':
        return Icons.account_balance_wallet_rounded;
      case 'moderation':
        return Icons.gavel_rounded;
      case 'accountDeletion':
        return Icons.person_remove_alt_1_rounded;
      case 'cache':
        return Icons.cloud_sync_rounded;
      case 'userAccess':
        return Icons.admin_panel_settings_rounded;
      default:
        return Icons.history_rounded;
    }
  }

  List<AdminActionItem> _filteredAdminActions(AdminDashboardModel data) {
    final items = data.latestAdminActions;
    if (_adminActionFilterKey.isEmpty) return items;
    final serverItems = data.adminActionsByCategory[_adminActionFilterKey];
    if (serverItems != null && serverItems.isNotEmpty) return serverItems;
    return items
        .where(
          (item) => _adminActionCategory(item) == _adminActionFilterKey,
        )
        .toList();
  }

  Widget _adminActionFilterChips(
    List<AdminActionItem> items, {
    Map<String, int> serverCounts = const <String, int>{},
  }) {
    final counts = <String, int>{};
    for (final item in items) {
      final key = _adminActionCategory(item);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    serverCounts.forEach((key, value) {
      final safeKey = key.trim();
      if (safeKey.isEmpty || value <= 0) return;
      counts[safeKey] = value;
    });
    final keys = _adminActionFilterKeys(counts);
    if (keys.isEmpty) return const SizedBox.shrink();

    final totalCount = serverCounts.isEmpty
        ? items.length
        : serverCounts.values.fold<int>(0, (sum, value) => sum + value);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ChoiceChip(
          selected: _adminActionFilterKey.isEmpty,
          onSelected: (_) => setState(() => _adminActionFilterKey = ''),
          avatar: Icon(
            Icons.all_inclusive_rounded,
            size: 16,
            color: _adminActionFilterKey.isEmpty
                ? const Color(0xFFFFFFFF)
                : const Color(0xFF374151),
          ),
          label: Text('All: $totalCount'),
          labelStyle: TextStyle(
            color: _adminActionFilterKey.isEmpty
                ? const Color(0xFFFFFFFF)
                : const Color(0xFF374151),
            fontWeight: FontWeight.w800,
          ),
          selectedColor: const Color(0xFF374151),
          backgroundColor: const Color(0xFFF3F4F6),
          side: BorderSide(
            color: const Color(0xFF374151).withValues(alpha: 0.24),
          ),
        ),
        ...keys.map((key) {
          final selected = _adminActionFilterKey == key;
          final fg = _adminActionCategoryFg(key);
          final bg = _adminActionCategoryBg(key);
          return ChoiceChip(
            selected: selected,
            onSelected: (_) {
              setState(() => _adminActionFilterKey = selected ? '' : key);
            },
            avatar: Icon(
              Icons.filter_alt_rounded,
              size: 16,
              color: selected ? const Color(0xFFFFFFFF) : fg,
            ),
            label: Text('${_adminActionFilterLabel(key)}: ${counts[key]}'),
            labelStyle: TextStyle(
              color: selected ? const Color(0xFFFFFFFF) : fg,
              fontWeight: FontWeight.w800,
            ),
            selectedColor: fg,
            backgroundColor: bg,
            side: BorderSide(color: fg.withValues(alpha: 0.24)),
          );
        }),
      ],
    );
  }

  Widget _adminActionCard(AdminActionItem item) {
    final actionId = item.id.isEmpty ? '' : 'Action: ${AppLog.safeId(item.id)}';
    final adminId =
        item.adminUid.isEmpty ? 'Unknown admin' : AppLog.safeId(item.adminUid);
    final targetId = item.targetUserId.isEmpty
        ? ''
        : 'Target: ${AppLog.safeId(item.targetUserId)}';
    final requestId = item.requestId.isEmpty
        ? ''
        : 'Request: ${AppLog.safeId(item.requestId)}';
    final reportId =
        item.reportId.isEmpty ? '' : 'Report: ${AppLog.safeId(item.reportId)}';
    final references = <String>[
      if (actionId.isNotEmpty) actionId,
      if (targetId.isNotEmpty) targetId,
      if (requestId.isNotEmpty) requestId,
      if (reportId.isNotEmpty) reportId,
    ].join(' - ');
    final before = [
      item.beforeStatus,
      item.beforeOutcome,
    ].where((part) => part.trim().isNotEmpty).join(' / ');
    final after = [
      item.afterStatus,
      item.afterOutcome,
    ].where((part) => part.trim().isNotEmpty).join(' / ');
    final transition = before.isEmpty && after.isEmpty
        ? ''
        : '${before.isEmpty ? 'previous' : before} -> ${after.isEmpty ? 'current' : after}';
    final note = item.note.isNotEmpty
        ? item.note
        : item.notePresent
            ? 'Admin note saved.'
            : '';
    final categoryKey = _adminActionCategory(item);
    final categoryLabel = _adminActionFilterLabel(categoryKey);
    final financeDetails = <String>[
      if (item.amount != 0)
        '${item.currency.isEmpty ? 'Amount' : item.currency}: ${item.amount}',
      if (item.ledgerTxId.isNotEmpty)
        'Ledger: ${AppLog.safeId(item.ledgerTxId)}',
      if (item.paymentReference.isNotEmpty)
        'Payout ref: ${item.paymentReference}',
      if (item.heldCredits > 0) 'Held: ${item.heldCredits}',
      if (item.pendingWithdrawalCreditsAfter > 0)
        'Pending after: ${item.pendingWithdrawalCreditsAfter}',
    ].join(' - ');
    final cacheDetails = <String>[
      if (item.totalUsers > 0) 'Users: ${item.totalUsers}',
      if (item.totalWithdrawalRequests > 0)
        'Withdrawals: ${item.totalWithdrawalRequests}',
      if (item.financeStatus.isNotEmpty) 'Finance: ${item.financeStatus}',
      'Warnings: ${item.financeWarningCount}',
    ].join(' - ');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: _adminActionCategoryBg(categoryKey),
            child: Icon(
              _adminActionCategoryIcon(categoryKey),
              color: _adminActionCategoryFg(categoryKey),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _adminActionTitle(item),
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(item.afterOutcome.isEmpty
                        ? item.afterStatus
                        : item.afterOutcome),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _pill(
                      categoryLabel,
                      bg: _adminActionCategoryBg(categoryKey),
                      fg: _adminActionCategoryFg(categoryKey),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Admin: $adminId${item.adminSource.isEmpty ? '' : ' (${item.adminSource})'}',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (references.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    references,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (transition.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'State: $transition',
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Note: $note',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (financeDetails.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    financeDetails,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                if (item.actionType == 'admin_dashboard_cache_refreshed') ...[
                  const SizedBox(height: 4),
                  Text(
                    cacheDetails,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF6B7280),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  item.retentionPolicyApplied
                      ? 'Retention policy applied - ${_dateLabel(item.createdAt)}'
                      : _dateLabel(item.createdAt),
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _reviewCard(AdminReviewItem item) {
    final reviewedUser = item.reviewedUserId.isEmpty
        ? 'Unknown'
        : AppLog.safeId(item.reviewedUserId);
    final callId = item.callId.isEmpty ? 'Unknown' : AppLog.safeId(item.callId);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFFFFFBEB),
            child: Text(
              '${item.stars}',
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFFD97706),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${item.stars} star review',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Reviewed user: $reviewedUser',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Call: $callId',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _dateLabel(item.createdAt),
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (item.text.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    item.text,
                    style: const TextStyle(
                      color: Color(0xFF374151),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _callCard(AdminCallItem item) {
    final caller = item.callerId.isEmpty ? 'Unknown' : item.callerId;
    final callee = item.calleeId.isEmpty ? 'Unknown' : item.calleeId;
    final reason = item.endedReason.isEmpty ? 'none' : item.endedReason;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFEEF2FF),
            child: Icon(
              Icons.call_rounded,
              color: Color(0xFF4F46E5),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Call ${item.id}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(item.status),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Caller: $caller',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Callee: $callee',
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Duration: ${item.durationSeconds}s - Billed: ${item.billedCredits} credits - Reason: $reason',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _dateLabel(item.updatedAt),
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _paymentOrderCard(AdminPaymentOrderItem item) {
    final userId = item.userId.isEmpty ? 'Unknown' : AppLog.safeId(item.userId);
    final gateway = item.gateway.isEmpty ? 'unknown' : item.gateway;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const CircleAvatar(
            backgroundColor: Color(0xFFFFFBEB),
            child: Icon(
              Icons.receipt_long_rounded,
              color: Color(0xFFD97706),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${item.currency} ${item.amount}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: Color(0xFF111827),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _statusChip(item.status),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'Order: ${AppLog.safeId(item.id)}',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF374151),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'User: $userId - Gateway: $gateway',
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _dateLabel(item.updatedAt),
                  style: const TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _userCard(AdminUserItem item) {
    final displayName =
        item.displayName.isEmpty ? 'Unnamed user' : item.displayName;
    final isBusy = _busyUserIds.contains(item.id);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CircleAvatar(
                backgroundColor: Color(0xFFEEF2FF),
                child: Icon(
                  Icons.person_rounded,
                  color: Color(0xFF4F46E5),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'User ID: ${AppLog.safeId(item.id)}',
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.isListener ? 'Role: Listener' : 'Role: User',
                      style: const TextStyle(
                        color: Color(0xFF374151),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.adminBlockedAt != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Blocked at: ${_dateLabel(item.adminBlockedAt)}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (item.adminBlockReason.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Reason: ${item.adminBlockReason}',
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _statusChip(item.adminBlocked ? 'blocked' : 'active'),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: item.adminBlocked
                ? OutlinedButton(
                    onPressed: isBusy ? null : () => _unblockUser(item),
                    child: Text(isBusy ? 'Working...' : 'Unblock user'),
                  )
                : FilledButton(
                    onPressed: isBusy ? null : () => _blockUser(item),
                    child: Text(isBusy ? 'Working...' : 'Block user'),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(String text) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          style: const TextStyle(
            color: Color(0xFF6B7280),
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildReportList(List<AdminReportItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No reports found.');
    }

    return Column(
      children: items.map(_reportCard).toList(),
    );
  }

  Widget _buildWithdrawalList(List<AdminWithdrawalItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No withdrawal rows match this view.');
    }

    return Column(
      children: items.map(_withdrawalCard).toList(),
    );
  }

  Widget _buildAccountDeletionRequestList(
    List<AdminAccountDeletionRequestItem> items,
  ) {
    if (items.isEmpty) {
      return _emptyCard('No account deletion requests found.');
    }

    return Column(
      children: items.map(_accountDeletionRequestCard).toList(),
    );
  }

  Widget _buildAdminActionList(
    List<AdminActionItem> items, {
    String emptyText = 'No admin actions recorded yet.',
  }) {
    if (items.isEmpty) {
      return _emptyCard(emptyText);
    }

    return Column(
      children: items.map(_adminActionCard).toList(),
    );
  }

  Widget _buildReviewList(List<AdminReviewItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No reviews found.');
    }

    return Column(
      children: items.map(_reviewCard).toList(),
    );
  }

  Widget _buildUserList(List<AdminUserItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No users found.');
    }

    return Column(
      children: items.map(_userCard).toList(),
    );
  }

  Widget _buildCallList(List<AdminCallItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No calls found.');
    }

    return Column(
      children: items.map(_callCard).toList(),
    );
  }

  Widget _buildPaymentOrderList(List<AdminPaymentOrderItem> items) {
    if (items.isEmpty) {
      return _emptyCard('No payment or top-up orders found.');
    }

    return Column(
      children: items.map(_paymentOrderCard).toList(),
    );
  }

  Widget _truthfulnessCard(AdminDashboardModel data) {
    final pendingShown = data.latestPendingWithdrawals.length;
    final pendingTotal = data.pendingWithdrawals;
    final cacheAgeSeconds = (data.cacheAgeMs / 1000).floor();
    final cacheTtlSeconds = (data.cacheTtlMs / 1000).floor();
    final cacheLabel = data.cacheHit ? 'cached' : data.cacheSource;

    return Card(
      color: const Color(0xFFFFFBEB),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Admin summary',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Dashboard totals and latest review queues are shown here.',
              style: TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Pending withdrawals total: $pendingTotal - currently shown in queue: $pendingShown',
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Data source: $cacheLabel'
              '${data.generatedAt == null ? '' : ' - generated ${_dateLabel(data.generatedAt)}'}'
              '${data.cacheTtlMs <= 0 ? '' : ' - age ${cacheAgeSeconds}s / TTL ${cacheTtlSeconds}s'}',
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Latest sections below intentionally show the newest limited items, not entire collection history.',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _financeReconciliationCard(AdminDashboardModel data) {
    final finance = data.financeReconciliation;
    final status = finance.status.trim().toLowerCase();
    final statusColor = finance.needsReview
        ? const Color(0xFFB91C1C)
        : status == 'balanced'
            ? const Color(0xFF047857)
            : const Color(0xFF6B7280);
    final statusText = finance.needsReview
        ? 'Review required'
        : status == 'balanced'
            ? 'Balanced'
            : 'Waiting for server data';

    Widget row(String label, int value) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '$value',
              style: const TextStyle(
                color: Color(0xFF111827),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      color: finance.needsReview
          ? const Color(0xFFFEF2F2)
          : status == 'balanced'
              ? const Color(0xFFECFDF5)
              : const Color(0xFFF9FAFB),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.account_balance_rounded, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Finance reconciliation - $statusText',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Read-only comparison of payment orders, wallet ledger, calls, withdrawals, and user liabilities.',
              style: TextStyle(
                color: finance.needsReview
                    ? const Color(0xFF7F1D1D)
                    : const Color(0xFF065F46),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            row(
              'Payment orders vs top-up ledger',
              finance.deltas.verifiedPaymentVsTopupLedger,
            ),
            row(
              'Call billed vs charge ledger',
              finance.deltas.callBilledVsChargeLedger,
            ),
            row(
              'Call payout vs earning ledger',
              finance.deltas.callPayoutVsEarningLedger,
            ),
            row(
              'Approved withdrawals vs ledger',
              finance.deltas.approvedWithdrawalVsLedger,
            ),
            row(
              'Pending holds vs user liability',
              finance.deltas.pendingWithdrawalHoldsVsUserLiability,
            ),
            row(
              'Active call reserves vs user liability',
              finance.deltas.activeCallReserveVsUserLiability,
            ),
            row(
              'Approved withdrawals missing payout ref',
              finance.withdrawals.approvedWithdrawalsMissingPaymentReference,
            ),
            row(
              'Approved withdrawals missing ledger proof',
              finance.withdrawals.approvedWithdrawalsMissingLedgerSettlement,
            ),
            const SizedBox(height: 8),
            Text(
              'User liability: ${finance.userLiability.total} credits | '
              'Call reserves: ${finance.calls.activeCallReservedAmount} credits | '
              'Pending holds: ${finance.withdrawals.pendingWithdrawalHeldAmount} credits | '
              'Ledger net movement: ${finance.walletLedger.netMovement} credits | '
              'Warnings: ${finance.warnings.length}',
              style: const TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            if (finance.warnings.isNotEmpty) ...[
              const SizedBox(height: 10),
              _financeWarningChips(finance),
            ],
          ],
        ),
      ),
    );
  }

  bool _adminActionLooksLikeRepair(AdminActionItem item) {
    final action = item.actionType.trim().toLowerCase();
    return action.contains('repair') ||
        action.contains('proof') ||
        action.contains('cache_refreshed') ||
        action.contains('backfill');
  }

  Widget _adminRepairRunSummaryCard(AdminDashboardModel data) {
    final finance = data.financeReconciliation;
    final pendingPaymentOrders = data.paymentOrderStatusCounts['pending'] ?? 0;
    final failedPaymentOrders = data.paymentOrderStatusCounts['failed'] ?? 0;
    final missingPayoutRefs =
        finance.withdrawals.approvedWithdrawalsMissingPaymentReference;
    final missingLedgerProofs =
        finance.withdrawals.approvedWithdrawalsMissingLedgerSettlement;
    final recentRepairActions =
        data.latestAdminActions.where(_adminActionLooksLikeRepair).length;
    final cacheActions = data.adminActionCategoryCounts['cache'] ?? 0;
    final openRepairItems = missingPayoutRefs +
        missingLedgerProofs +
        pendingPaymentOrders +
        failedPaymentOrders;
    final healthy = openRepairItems == 0 && !finance.needsReview;
    final bg = healthy ? const Color(0xFFECFDF5) : const Color(0xFFFFFBEB);
    final fg = healthy ? const Color(0xFF047857) : const Color(0xFFB45309);

    Widget summaryMetric(String label, int value, IconData icon) {
      return Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF).withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: fg.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(height: 8),
            Text(
              '$value',
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.2,
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  healthy ? Icons.verified_rounded : Icons.engineering_rounded,
                  color: fg,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    healthy
                        ? 'Repair run summary - clear'
                        : 'Repair run summary - action needed',
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                _pill(
                  healthy ? 'Clear' : '$openRepairItems open',
                  bg: healthy
                      ? const Color(0xFFD1FAE5)
                      : const Color(0xFFFEF3C7),
                  fg: fg,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              healthy
                  ? 'No finance repair warnings or payment-order exceptions are visible in the current dashboard snapshot.'
                  : 'Use this snapshot to prioritize payout proof, ledger proof, cache, and payment-order follow-up from one place.',
              style: const TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                summaryMetric(
                  'Missing payout refs',
                  missingPayoutRefs,
                  Icons.payments_rounded,
                ),
                summaryMetric(
                  'Missing ledger proof',
                  missingLedgerProofs,
                  Icons.account_balance_rounded,
                ),
                summaryMetric(
                  'Pending payments',
                  pendingPaymentOrders,
                  Icons.hourglass_bottom_rounded,
                ),
                summaryMetric(
                  'Failed payments',
                  failedPaymentOrders,
                  Icons.error_rounded,
                ),
                summaryMetric(
                  'Recent repair actions',
                  recentRepairActions,
                  Icons.build_circle_rounded,
                ),
                summaryMetric(
                  'Cache refresh actions',
                  cacheActions,
                  Icons.cloud_sync_rounded,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _maintenanceToolsCard() {
    Widget progressIcon(IconData icon, bool busy) {
      if (!busy) return Icon(icon);
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }

    return Card(
      color: const Color(0xFFF8FAFC),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Maintenance tools',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Run these after migrations or data repairs to rebuild public profile projections and follower-derived user fields.',
              style: TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed:
                      _backfillingPublicUsers ? null : _backfillPublicUsers,
                  icon: progressIcon(
                    Icons.people_alt_outlined,
                    _backfillingPublicUsers,
                  ),
                  label: Text(
                    _backfillingPublicUsers
                        ? 'Backfilling public users'
                        : 'Backfill public users',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _backfillingFollowersCount
                      ? null
                      : _backfillFollowersCount,
                  icon: progressIcon(
                    Icons.groups_2_outlined,
                    _backfillingFollowersCount,
                  ),
                  label: Text(
                    _backfillingFollowersCount
                        ? 'Backfilling followers'
                        : 'Backfill followers',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _launchOversightCard() {
    return const Card(
      color: Color(0xFFFFFBEB),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Launch oversight',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Use this to monitor launch-facing readiness items that still need founder/legal completion:',
              style: TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            SizedBox(height: 10),
            Text(
              '- Privacy Policy final content/link\n'
              '- Terms of Service final content/link\n'
              '- Refund Policy final content\n'
              '- Support / Grievance contact visibility\n'
              '- Delete account operational handling\n'
              '- Payment mode honesty (sandbox / manual / live)\n'
              '- Crisis help escalation details',
              style: TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AdminDashboardModel data) {
    final pendingShown = data.latestPendingWithdrawals.length;
    final pendingTotal = data.pendingWithdrawals;
    final visibleWithdrawals = _withdrawalsForDrilldown(data);
    final withdrawalFilterActive =
        _warningCanFilterWithdrawals(_withdrawalDrilldownKey);
    final pendingSubtitle =
        'Showing latest $pendingShown recent withdrawal rows. Pending total: $pendingTotal.';
    final withdrawalWarningTotal = withdrawalFilterActive
        ? _financeWarningTotal(
            data.financeReconciliation, _withdrawalDrilldownKey)
        : 0;
    final withdrawalTotal = withdrawalWarningTotal > 0
        ? withdrawalWarningTotal
        : visibleWithdrawals.length;
    final withdrawalSubtitle = withdrawalFilterActive
        ? '${_financeWarningLabel(_withdrawalDrilldownKey)} - ${visibleWithdrawals.length} shown out of $withdrawalTotal total.'
        : pendingSubtitle;
    final visibleAdminActions = _filteredAdminActions(data);
    final adminActionFilterActive = _adminActionFilterKey.isNotEmpty;
    final selectedAdminActionTotal = adminActionFilterActive
        ? data.adminActionCategoryCounts[_adminActionFilterKey] ??
            visibleAdminActions.length
        : data.adminActionCategoryCounts.values.fold<int>(
            0,
            (sum, value) => sum + value,
          );
    final adminActionTotal = selectedAdminActionTotal > 0
        ? selectedAdminActionTotal
        : data.latestAdminActions.length;
    final adminActionSubtitle = adminActionFilterActive
        ? '${_adminActionFilterLabel(_adminActionFilterKey)} actions - ${visibleAdminActions.length} shown out of $adminActionTotal total.'
        : 'Recent backend-reviewed admin decisions for support and audit checks.';
    final visiblePaymentOrders = _filteredPaymentOrders(data);
    final paymentOrderFilterActive = _paymentOrderFilterKey.isNotEmpty;
    final selectedPaymentOrderTotal = paymentOrderFilterActive
        ? data.paymentOrderStatusCounts[_paymentOrderFilterKey] ??
            visiblePaymentOrders.length
        : data.paymentOrderStatusCounts.values.fold<int>(
            0,
            (sum, value) => sum + value,
          );
    final paymentOrderTotal = selectedPaymentOrderTotal > 0
        ? selectedPaymentOrderTotal
        : data.latestPaymentOrders.length;
    final paymentOrderSubtitle = paymentOrderFilterActive
        ? '${_paymentOrderFilterLabel(_paymentOrderFilterKey)} orders - ${visiblePaymentOrders.length} shown out of $paymentOrderTotal total.'
        : 'Recent wallet order status for payment support.';
    final deleteRequestShown = data.latestAccountDeletionRequests.length;
    final deleteRequestTotal = data.pendingAccountDeletionRequests;
    final deleteRequestSubtitle = deleteRequestTotal > deleteRequestShown
        ? 'Showing latest $deleteRequestShown requests out of $deleteRequestTotal pending delete-account requests.'
        : 'Showing current delete-account request queue.';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      children: [
        _sectionCard(
          title: 'Admin moderation dashboard',
          subtitle:
              'Operational read surface for moderation, withdrawals, reviews, and basic user controls.',
          trailing: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                onPressed: () => _reload(forceRefresh: true),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reload'),
              ),
              FilledButton.icon(
                onPressed: _refreshingServerCache ? null : _refreshServerCache,
                icon: _refreshingServerCache
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.cloud_sync_rounded),
                label: const Text('Rebuild cache'),
              ),
            ],
          ),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill('Monitor reports'),
                _pill('Track withdrawals'),
                _pill('Review calls'),
                _pill('Audit payments'),
                _pill('Review content'),
                _pill('Moderate users'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _truthfulnessCard(data),
        const SizedBox(height: 12),
        _financeReconciliationCard(data),
        const SizedBox(height: 12),
        _adminRepairRunSummaryCard(data),
        const SizedBox(height: 12),
        _maintenanceToolsCard(),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.18,
          children: [
            _metricCard(
              label: 'Total users',
              value: '${data.totalUsers}',
              color: const Color(0xFF4F46E5),
              icon: Icons.people_alt_rounded,
              highlight: true,
            ),
            _metricCard(
              label: 'Total listeners',
              value: '${data.totalListeners}',
              color: const Color(0xFF15803D),
              icon: Icons.headset_mic_rounded,
            ),
            _metricCard(
              label: 'Admin-blocked users',
              value: '${data.blockedRelationships}',
              color: const Color(0xFFDC2626),
              icon: Icons.block_rounded,
            ),
            _metricCard(
              label: 'Total reports',
              value: '${data.totalReports}',
              color: const Color(0xFFD97706),
              icon: Icons.flag_rounded,
            ),
            _metricCard(
              label: 'Pending withdrawals',
              value: '$pendingTotal',
              color: const Color(0xFFF59E0B),
              icon: Icons.hourglass_bottom_rounded,
              subtitle: pendingShown > 0 ? '$pendingShown shown below' : null,
            ),
            _metricCard(
              label: 'Total reviews',
              value: '${data.totalReviews}',
              color: const Color(0xFF7C3AED),
              icon: Icons.reviews_rounded,
            ),
            _metricCard(
              label: 'Total calls',
              value: '${data.totalCalls}',
              color: const Color(0xFF2563EB),
              icon: Icons.call_rounded,
            ),
            _metricCard(
              label: 'Payment orders',
              value: '${data.totalPaymentOrders}',
              color: const Color(0xFF0891B2),
              icon: Icons.receipt_long_rounded,
              subtitle: 'Verified: ${data.totalTopupAmount} credits',
            ),
            _metricCard(
              label: 'Delete requests',
              value: '${data.pendingAccountDeletionRequests}',
              color: const Color(0xFFE11D48),
              icon: Icons.person_remove_alt_1_rounded,
              subtitle: deleteRequestShown > 0
                  ? '$deleteRequestShown shown below'
                  : null,
            ),
          ],
        ),
        const SizedBox(height: 16),
        _sectionHeader(
          'Latest users',
          subtitle: 'Basic admin moderation controls for user access.',
        ),
        const SizedBox(height: 10),
        _buildUserList(data.latestUsers),
        const SizedBox(height: 16),
        _sectionHeader(
          'Latest reports',
          subtitle: 'Newest moderation reports submitted by users.',
        ),
        const SizedBox(height: 10),
        _buildReportList(data.latestReports),
        const SizedBox(height: 16),
        _sectionHeader(
          'Withdrawal review queue',
          subtitle: withdrawalSubtitle,
          trailing: withdrawalFilterActive
              ? OutlinedButton.icon(
                  onPressed: () => setState(() => _withdrawalDrilldownKey = ''),
                  icon: const Icon(Icons.filter_alt_off_rounded),
                  label: const Text('Clear'),
                )
              : null,
        ),
        const SizedBox(height: 10),
        _buildWithdrawalList(visibleWithdrawals),
        const SizedBox(height: 16),
        _sectionHeader(
          'Delete account requests',
          subtitle: deleteRequestSubtitle,
        ),
        const SizedBox(height: 10),
        _buildAccountDeletionRequestList(data.latestAccountDeletionRequests),
        const SizedBox(height: 16),
        _sectionHeader(
          'Admin action trail',
          subtitle: adminActionSubtitle,
          trailing: adminActionFilterActive
              ? OutlinedButton.icon(
                  onPressed: () => setState(() => _adminActionFilterKey = ''),
                  icon: const Icon(Icons.filter_alt_off_rounded),
                  label: const Text('Clear'),
                )
              : null,
        ),
        const SizedBox(height: 10),
        _adminActionFilterChips(
          data.latestAdminActions,
          serverCounts: data.adminActionCategoryCounts,
        ),
        if (data.latestAdminActions.isNotEmpty) const SizedBox(height: 10),
        _buildAdminActionList(
          visibleAdminActions,
          emptyText:
              'No ${_adminActionFilterLabel(_adminActionFilterKey).toLowerCase()} admin actions in the recent trail.',
        ),
        const SizedBox(height: 16),
        _sectionHeader(
          'Latest calls',
          subtitle: 'Recent call state, billing, and participant IDs.',
        ),
        const SizedBox(height: 10),
        _buildCallList(data.latestCalls),
        const SizedBox(height: 16),
        _sectionHeader(
          'Latest payment / top-up orders',
          subtitle: paymentOrderSubtitle,
          trailing: paymentOrderFilterActive
              ? OutlinedButton.icon(
                  onPressed: () => setState(() => _paymentOrderFilterKey = ''),
                  icon: const Icon(Icons.filter_alt_off_rounded),
                  label: const Text('Clear'),
                )
              : null,
        ),
        const SizedBox(height: 10),
        _paymentOrderFilterChips(
          data.latestPaymentOrders,
          serverCounts: data.paymentOrderStatusCounts,
        ),
        if (data.latestPaymentOrders.isNotEmpty) const SizedBox(height: 10),
        _buildPaymentOrderList(visiblePaymentOrders),
        const SizedBox(height: 16),
        _sectionHeader(
          'Latest reviews',
          subtitle: 'Recent feedback and ratings coming from completed calls.',
        ),
        const SizedBox(height: 10),
        _buildReviewList(data.latestReviews),
        const SizedBox(height: 16),
        _launchOversightCard(),
      ],
    );
  }

  Widget _buildPermissionDeniedCard() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.admin_panel_settings_outlined,
                  size: 52,
                  color: Color(0xFF9CA3AF),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Admin access required',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This dashboard is protected by backend admin checks.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xFF6B7280),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: () => _reload(forceRefresh: true),
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
      ),
      body: FutureBuilder<AdminDashboardModel>(
        future: _future,
        builder: (_, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snap.hasError) {
            if (_looksLikePermissionError(snap.error!)) {
              return _buildPermissionDeniedCard();
            }

            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.admin_panel_settings_outlined,
                      size: 52,
                      color: Color(0xFF9CA3AF),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not load admin dashboard',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF111827),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Please try again, or check your admin access.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: () => _reload(forceRefresh: true),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final data = snap.data ?? AdminDashboardModel.empty();

          return RefreshIndicator(
            onRefresh: () => _reload(forceRefresh: true),
            child: _buildBody(data),
          );
        },
      ),
    );
  }
}
