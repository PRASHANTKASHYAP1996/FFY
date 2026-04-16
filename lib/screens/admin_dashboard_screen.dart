import 'package:flutter/material.dart';

import '../repositories/admin_repository.dart';
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

  @override
  void initState() {
    super.initState();
    _future = _repository.loadDashboard();
  }

  Future<void> _reload() async {
    setState(() {
      _future = _repository.loadDashboard();
    });
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

  Future<void> _approveWithdrawal(AdminWithdrawalItem item) async {
    if (_busyWithdrawalIds.contains(item.id)) return;

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.approveWithdrawal(item.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal approved.')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Approve failed: $e')),
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

    setState(() {
      _busyWithdrawalIds.add(item.id);
    });

    try {
      await _repository.rejectWithdrawal(item.id);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Withdrawal rejected.')),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reject failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyWithdrawalIds.remove(item.id);
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
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Block failed: $e')),
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
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unblock failed: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busyUserIds.remove(item.id);
        });
      }
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
          final valueFontSize = highlight
              ? (compact ? 20.0 : 24.0)
              : (compact ? 17.0 : 20.0);
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
        color = const Color(0xFFD97706);
        break;
      case 'approved':
      case 'paid':
      case 'completed':
      case 'active':
        color = const Color(0xFF15803D);
        break;
      case 'rejected':
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

  Widget _reportCard(AdminReportItem item) {
    final reason = item.reason.isEmpty ? 'No reason' : item.reason;
    final reportedUser =
        item.reportedUserId.isEmpty ? 'Unknown' : item.reportedUserId;
    final callId = item.callId.isEmpty ? 'Unknown' : item.callId;

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
                Text(
                  reason,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF111827),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Reported user: $reportedUser',
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
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _withdrawalCard(AdminWithdrawalItem item) {
    final userId = item.userId.isEmpty ? 'Unknown' : item.userId;
    final isPending = item.status.trim().toLowerCase() == 'pending';
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
                      '₹${item.amount}',
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
          ],
        ],
      ),
    );
  }

  Widget _reviewCard(AdminReviewItem item) {
    final reviewedUser =
        item.reviewedUserId.isEmpty ? 'Unknown' : item.reviewedUserId;
    final callId = item.callId.isEmpty ? 'Unknown' : item.callId;

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
                      'User ID: ${item.id}',
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
      return _emptyCard('No pending withdrawal review items found.');
    }

    return Column(
      children: items.map(_withdrawalCard).toList(),
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

  Widget _truthfulnessCard(AdminDashboardModel data) {
    final pendingShown = data.latestPendingWithdrawals.length;
    final pendingTotal = data.pendingWithdrawals;

    return Card(
      color: const Color(0xFFFFFBEB),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Admin truthfulness note',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: Color(0xFF111827),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This screen shows dashboard totals plus a latest-items operational queue. It is not a full raw-document browser for every collection.',
              style: const TextStyle(
                color: Color(0xFF374151),
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Pending withdrawals total: $pendingTotal • currently shown in queue: $pendingShown',
              style: const TextStyle(
                color: Color(0xFF6B7280),
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Latest withdrawals section below is intentionally a pending review queue, not the entire withdrawal history.',
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

  Widget _launchOversightCard() {
    return Card(
      color: const Color(0xFFFFFBEB),
      child: const Padding(
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
              '• Privacy Policy final content/link\n'
              '• Terms of Service final content/link\n'
              '• Refund Policy final content\n'
              '• Support / Grievance contact visibility\n'
              '• Delete account operational handling\n'
              '• Payment mode honesty (sandbox / manual / live)\n'
              '• Crisis help escalation details',
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
    final pendingSubtitle = pendingTotal > pendingShown
        ? 'Showing latest $pendingShown pending items out of $pendingTotal total pending requests.'
        : 'Showing current pending review queue.';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
      children: [
        _sectionCard(
          title: 'Admin moderation dashboard',
          subtitle:
              'Operational read surface for moderation, withdrawals, reviews, and basic user controls.',
          trailing: FilledButton.icon(
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Refresh'),
          ),
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _pill('Monitor reports'),
                _pill('Track withdrawals'),
                _pill('Review content'),
                _pill('Moderate users'),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        _truthfulnessCard(data),
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
              label: 'Blocked relationships',
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
          'Pending withdrawal review queue',
          subtitle: pendingSubtitle,
        ),
        const SizedBox(height: 10),
        _buildWithdrawalList(data.latestPendingWithdrawals),
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

  Widget _buildPermissionDeniedCard(Object error) {
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
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _reload,
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
              return _buildPermissionDeniedCard(snap.error!);
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
                    Text(
                      '${snap.error}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF6B7280),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 14),
                    FilledButton.icon(
                      onPressed: _reload,
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
            onRefresh: _reload,
            child: _buildBody(data),
          );
        },
      ),
    );
  }
}