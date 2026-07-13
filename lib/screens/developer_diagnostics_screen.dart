import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import '../core/constants/agora_client_config.dart';
import '../core/constants/firestore_paths.dart';
import '../repositories/admin_repository.dart';
import '../services/call_manager.dart';

class DeveloperDiagnosticsScreen extends StatefulWidget {
  const DeveloperDiagnosticsScreen({super.key});

  @override
  State<DeveloperDiagnosticsScreen> createState() =>
      _DeveloperDiagnosticsScreenState();
}

class _DeveloperDiagnosticsScreenState
    extends State<DeveloperDiagnosticsScreen> {
  final FirebaseApp _app = Firebase.app();
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _db = FirebaseFirestore.instance;
  final FirebaseAppCheck _appCheck = FirebaseAppCheck.instance;
  final AdminRepository _adminRepository = AdminRepository.instance;

  bool _running = false;
  DateTime? _lastRunAt;

  DiagnosticProbeResult? _appCheckResult;
  DiagnosticProbeResult? _userDocResult;
  DiagnosticProbeResult? _publicUserDocResult;
  DiagnosticProbeResult? _agoraServerConfigResult;
  DiagnosticProbeResult? _recentChatsResult;
  DiagnosticProbeResult? _incomingRequestsResult;
  String _fullScreenCallPermissionStatus = 'Unknown';

  String get _uid => _auth.currentUser?.uid.trim() ?? '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _runDiagnostics();
    });
  }

  Future<void> _runDiagnostics() async {
    if (_running) return;

    setState(() {
      _running = true;
    });

    final uid = _uid;
    final appCheck = await _runAppCheckProbe();
    final userDoc = await _runUsersProbe(uid);
    final publicUserDoc = await _runPublicUsersProbe(uid);
    final agoraServerConfig = await _runAgoraServerConfigProbe();
    final recentChats = await _runRecentChatsProbe(uid);
    final incomingRequests = await _runIncomingRequestsProbe(uid);
    final fullScreenCallPermission =
        await CallManager.instance.nativeFullScreenCallPermissionStatus();

    if (!mounted) return;

    setState(() {
      _appCheckResult = appCheck;
      _userDocResult = userDoc;
      _publicUserDocResult = publicUserDoc;
      _agoraServerConfigResult = agoraServerConfig;
      _recentChatsResult = recentChats;
      _incomingRequestsResult = incomingRequests;
      _fullScreenCallPermissionStatus = fullScreenCallPermission;
      _lastRunAt = DateTime.now();
      _running = false;
    });
  }

  Future<DiagnosticProbeResult> _runAppCheckProbe() async {
    try {
      final token = await _appCheck.getToken(true);
      final hasToken = (token ?? '').trim().isNotEmpty;
      return DiagnosticProbeResult.success(
        title: 'App Check getToken(true)',
        message: hasToken
            ? 'Success. Token received.'
            : 'Success, but token was empty.',
        details: !hasToken
            ? 'Operation: FirebaseAppCheck.instance.getToken(true)'
            : 'Operation: FirebaseAppCheck.instance.getToken(true)\n'
                'Token value is intentionally not displayed.',
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'App Check getToken(true)',
        error: error,
        operation: 'FirebaseAppCheck.instance.getToken(true)',
      );
    }
  }

  Future<DiagnosticProbeResult> _runUsersProbe(String uid) async {
    if (uid.isEmpty) {
      return const DiagnosticProbeResult.error(
        title: 'users/{uid}.get()',
        message: 'No signed-in user found.',
        details: 'Operation skipped because current auth uid is empty.',
      );
    }

    try {
      final snap = await _db.collection(FirestorePaths.users).doc(uid).get();
      return DiagnosticProbeResult.success(
        title: 'users/{uid}.get()',
        message: 'Success. exists=${snap.exists}.',
        details: 'Path: ${FirestorePaths.userDoc(uid)}\n'
            '${snap.exists ? _describeMap(snap.data() ?? <String, dynamic>{}) : 'No fields returned.'}',
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'users/{uid}.get()',
        error: error,
        operation: 'Path: ${FirestorePaths.userDoc(uid)}',
      );
    }
  }

  Future<DiagnosticProbeResult> _runPublicUsersProbe(String uid) async {
    if (uid.isEmpty) {
      return const DiagnosticProbeResult.error(
        title: 'public_users/{uid}.get()',
        message: 'No signed-in user found.',
        details: 'Operation skipped because current auth uid is empty.',
      );
    }

    try {
      final snap =
          await _db.collection(FirestorePaths.publicUsers).doc(uid).get();
      return DiagnosticProbeResult.success(
        title: 'public_users/{uid}.get()',
        message: 'Success. exists=${snap.exists}.',
        details: 'Path: ${FirestorePaths.publicUserDoc(uid)}\n'
            '${snap.exists ? _describeMap(snap.data() ?? <String, dynamic>{}) : 'No fields returned.'}',
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'public_users/{uid}.get()',
        error: error,
        operation: 'Path: ${FirestorePaths.publicUserDoc(uid)}',
      );
    }
  }

  Future<DiagnosticProbeResult> _runRecentChatsProbe(String uid) async {
    if (uid.isEmpty) {
      return const DiagnosticProbeResult.error(
        title: 'Recent Chats Query',
        message: 'No signed-in user found.',
        details: 'Operation skipped because current auth uid is empty.',
      );
    }

    try {
      final query = await _db
          .collection(FirestorePaths.chatSessions)
          .where(FirestorePaths.fieldParticipantIds, arrayContains: uid)
          .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
          .limit(5)
          .get();

      return DiagnosticProbeResult.success(
        title: 'Recent Chats Query',
        message: 'Success. ${query.docs.length} document(s) returned.',
        details:
            'Query: chat_sessions where participantIds arrayContains currentUser.uid orderBy updatedAtMs desc\n'
            '${_describeDocs(query.docs)}',
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'Recent Chats Query',
        error: error,
        operation:
            'Query: chat_sessions where participantIds arrayContains currentUser.uid orderBy updatedAtMs desc',
      );
    }
  }

  Future<DiagnosticProbeResult> _runIncomingRequestsProbe(String uid) async {
    if (uid.isEmpty) {
      return const DiagnosticProbeResult.error(
        title: 'Incoming Requests Query',
        message: 'No signed-in user found.',
        details: 'Operation skipped because current auth uid is empty.',
      );
    }

    try {
      final query = await _db
          .collection(FirestorePaths.chatSessions)
          .where(FirestorePaths.fieldParticipantIds, arrayContains: uid)
          .where(FirestorePaths.fieldPendingFor, isEqualTo: uid)
          .where(FirestorePaths.fieldCallRequestOpen, isEqualTo: true)
          .orderBy(FirestorePaths.fieldChatUpdatedAtMs, descending: true)
          .limit(5)
          .get();

      return DiagnosticProbeResult.success(
        title: 'Incoming Requests Query',
        message: 'Success. ${query.docs.length} document(s) returned.',
        details:
            'Query: chat_sessions where participantIds arrayContains currentUser.uid and pendingFor == currentUser.uid and callRequestOpen == true orderBy updatedAtMs desc\n'
            '${_describeDocs(query.docs)}',
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'Incoming Requests Query',
        error: error,
        operation:
            'Query: chat_sessions where participantIds arrayContains currentUser.uid and pendingFor == currentUser.uid and callRequestOpen == true orderBy updatedAtMs desc',
      );
    }
  }

  Future<DiagnosticProbeResult> _runAgoraServerConfigProbe() async {
    try {
      final data = await _adminRepository.checkAgoraServerConfig();
      final ready = data['ready'] == true;
      final appIdPresent = data['appIdPresent'] == true;
      final certificatePresent = data['certificatePresent'] == true;
      final tokenBuilderAvailable = data['tokenBuilderAvailable'] == true;
      final details = 'Callable: checkAgoraServerConfig_v1\n'
          'ready: $ready\n'
          'appIdPresent: $appIdPresent\n'
          'certificatePresent: $certificatePresent\n'
          'tokenBuilderAvailable: $tokenBuilderAvailable';

      if (ready) {
        return DiagnosticProbeResult.success(
          title: 'Agora Server Config',
          message: 'Server token configuration is ready.',
          details: details,
        );
      }

      return DiagnosticProbeResult.warning(
        title: 'Agora Server Config',
        message: 'Server token configuration is incomplete.',
        details: details,
      );
    } catch (error) {
      return _firebaseErrorResult(
        title: 'Agora Server Config',
        error: error,
        operation: 'Callable: checkAgoraServerConfig_v1',
      );
    }
  }

  DiagnosticProbeResult _firebaseErrorResult({
    required String title,
    required Object error,
    required String operation,
  }) {
    final formatted = _formatError(error);
    return DiagnosticProbeResult.error(
      title: title,
      message: formatted.summary,
      details: '$operation\n'
          'Exception type: ${formatted.type}\n'
          'Code: ${formatted.code}\n'
          'Message: ${formatted.message}\n'
          'Raw: ${formatted.raw}',
    );
  }

  _FormattedError _formatError(Object error) {
    if (error is FirebaseException) {
      return _FormattedError(
        type: error.runtimeType.toString(),
        code: error.code,
        message: (error.message ?? '').trim().isEmpty
            ? '(empty)'
            : error.message!.trim(),
        raw: error.toString(),
        summary:
            'FirebaseException(code=${error.code}, message=${(error.message ?? '').trim().isEmpty ? '(empty)' : error.message!.trim()})',
      );
    }

    return _FormattedError(
      type: error.runtimeType.toString(),
      code: '(not a FirebaseException)',
      message: error.toString(),
      raw: error.toString(),
      summary: error.toString(),
    );
  }

  String _describeDocs(List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    if (docs.isEmpty) return 'No documents returned.';
    return docs
        .map(
          (doc) =>
              '- ${doc.id}: pairKey=${doc.data()[FirestorePaths.fieldPairKey] ?? ''}, updatedAtMs=${doc.data()[FirestorePaths.fieldChatUpdatedAtMs] ?? ''}',
        )
        .join('\n');
  }

  String _describeMap(Map<String, dynamic> data) {
    if (data.isEmpty) return 'No fields returned.';
    final keys = data.keys.toList()..sort();
    return keys.take(16).map((key) => '- $key: ${data[key]}').join('\n');
  }

  Widget _projectIdentityCard() {
    final options = _app.options;
    final agoraReadiness = AgoraClientConfig.currentReadiness;
    return _card(
      title: 'Firebase Identity',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _kv('Project id', options.projectId),
          _kv('App id', options.appId),
          _kv('Current auth uid', _uid.isEmpty ? '(not signed in)' : _uid),
          _kv(
            'Current auth email',
            _auth.currentUser?.email?.trim().isNotEmpty == true
                ? _auth.currentUser!.email!.trim()
                : '(none)',
          ),
          _kv(
            'Last run',
            _lastRunAt?.toIso8601String() ?? 'Running first check...',
          ),
          _kv(
            'Agora Client App ID',
            agoraReadiness.clientAppIdStatus,
          ),
          _kv(
            'Full-screen call permission',
            _fullScreenCallPermissionStatus,
          ),
          if (!agoraReadiness.isReady)
            _kv(
              'Agora run command',
              AgoraClientConfig.developerRunCommandMessage,
            ),
        ],
      ),
    );
  }

  Widget _probeCard(DiagnosticProbeResult? result) {
    if (result == null) {
      return _card(
        title: 'Pending',
        child: const Text('This probe has not run yet.'),
      );
    }

    final colors = switch (result.status) {
      DiagnosticProbeStatus.success => _ProbeColors.success,
      DiagnosticProbeStatus.warning => _ProbeColors.warning,
      DiagnosticProbeStatus.error => _ProbeColors.error,
    };

    return _card(
      title: result.title,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: colors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.statusLabel,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: colors.foreground,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
              result.message,
              style: TextStyle(
                color: colors.foreground,
                fontWeight: FontWeight.w700,
                height: 1.35,
              ),
            ),
            if (result.details != null &&
                result.details!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(
                result.details!,
                style: const TextStyle(
                  color: Color(0xFF374151),
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _card({required String title, required Widget child}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
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
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _kv(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            color: Color(0xFF374151),
            fontSize: 14,
            height: 1.4,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('Developer Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Run checks again',
            onPressed: _running ? null : _runDiagnostics,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _projectIdentityCard(),
          const SizedBox(height: 12),
          _probeCard(_appCheckResult),
          const SizedBox(height: 12),
          _probeCard(_userDocResult),
          const SizedBox(height: 12),
          _probeCard(_publicUserDocResult),
          const SizedBox(height: 12),
          _probeCard(_agoraServerConfigResult),
          const SizedBox(height: 12),
          _probeCard(_recentChatsResult),
          const SizedBox(height: 12),
          _probeCard(_incomingRequestsResult),
        ],
      ),
    );
  }
}

enum DiagnosticProbeStatus { success, warning, error }

class DiagnosticProbeResult {
  const DiagnosticProbeResult._({
    required this.title,
    required this.message,
    required this.status,
    this.details,
  });

  const DiagnosticProbeResult.success({
    required String title,
    required String message,
    String? details,
  }) : this._(
          title: title,
          message: message,
          status: DiagnosticProbeStatus.success,
          details: details,
        );

  const DiagnosticProbeResult.warning({
    required String title,
    required String message,
    String? details,
  }) : this._(
          title: title,
          message: message,
          status: DiagnosticProbeStatus.warning,
          details: details,
        );

  const DiagnosticProbeResult.error({
    required String title,
    required String message,
    String? details,
  }) : this._(
          title: title,
          message: message,
          status: DiagnosticProbeStatus.error,
          details: details,
        );

  final String title;
  final String message;
  final String? details;
  final DiagnosticProbeStatus status;

  String get statusLabel {
    switch (status) {
      case DiagnosticProbeStatus.success:
        return 'Success';
      case DiagnosticProbeStatus.warning:
        return 'Warning';
      case DiagnosticProbeStatus.error:
        return 'Error';
    }
  }
}

class _FormattedError {
  const _FormattedError({
    required this.type,
    required this.code,
    required this.message,
    required this.raw,
    required this.summary,
  });

  final String type;
  final String code;
  final String message;
  final String raw;
  final String summary;
}

class _ProbeColors {
  const _ProbeColors._({
    required this.background,
    required this.border,
    required this.foreground,
  });

  static const success = _ProbeColors._(
    background: Color(0xFFECFDF3),
    border: Color(0xFFA7F3D0),
    foreground: Color(0xFF166534),
  );

  static const warning = _ProbeColors._(
    background: Color(0xFFFFFBEB),
    border: Color(0xFFFDE68A),
    foreground: Color(0xFF92400E),
  );

  static const error = _ProbeColors._(
    background: Color(0xFFFEF2F2),
    border: Color(0xFFFECACA),
    foreground: Color(0xFF991B1B),
  );

  final Color background;
  final Color border;
  final Color foreground;
}
