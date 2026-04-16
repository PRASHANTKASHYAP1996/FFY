class FirestorePaths {
  FirestorePaths._();

  // ---------------- COLLECTIONS ----------------

  static const String users = 'users';
  static const String publicUsers = 'public_users';
  static const String calls = 'calls';
  static const String reviews = 'reviews';
  static const String reports = 'reports';
  static const String rateLimits = 'rate_limits';
  static const String walletTransactions = 'wallet_transactions';
  static const String withdrawalRequests = 'withdrawal_requests';
  static const String paymentOrders = 'payment_orders';
  static const String walletLocks = 'wallet_locks';

  // Chat
  static const String chatSessions = 'chat_sessions';
  static const String messages = 'messages';

  // ---------------- PATH HELPERS ----------------

  static String userDoc(String uid) => '$users/$uid';
  static String publicUserDoc(String uid) => '$publicUsers/$uid';
  static String callDoc(String callId) => '$calls/$callId';
  static String reviewDoc(String reviewId) => '$reviews/$reviewId';
  static String reportDoc(String reportId) => '$reports/$reportId';
  static String rateLimitDoc(String uid) => '$rateLimits/$uid';
  static String walletTransactionDoc(String txId) =>
      '$walletTransactions/$txId';
  static String withdrawalRequestDoc(String requestId) =>
      '$withdrawalRequests/$requestId';
  static String paymentOrderDoc(String orderId) => '$paymentOrders/$orderId';
  static String walletLockDoc(String lockId) => '$walletLocks/$lockId';

  static String chatSessionDocById(String sessionId) =>
      '$chatSessions/$sessionId';

  static String chatSessionDoc({
    required String speakerId,
    required String listenerId,
  }) =>
      '$chatSessions/${speakerId}_$listenerId';

  static String chatMessagesCollection(String sessionId) =>
      '$chatSessions/$sessionId/$messages';

  static String chatMessageDoc({
    required String sessionId,
    required String messageId,
  }) =>
      '$chatSessions/$sessionId/$messages/$messageId';

  // ---------------- USER FIELDS ----------------

  static const String fieldUid = 'uid';
  static const String fieldEmail = 'email';
  static const String fieldDisplayName = 'displayName';

  static const String fieldCredits = 'credits';
  static const String fieldReservedCredits = 'reservedCredits';
  static const String fieldEarningsCredits = 'earningsCredits';
  static const String fieldPlatformRevenueCredits = 'platformRevenueCredits';

  static const String fieldPhotoURL = 'photoURL';
  static const String fieldBio = 'bio';
  static const String fieldGender = 'gender';
  static const String fieldCity = 'city';
  static const String fieldState = 'state';
  static const String fieldCountry = 'country';

  static const String fieldTopics = 'topics';
  static const String fieldLanguages = 'languages';

  static const String fieldIsListener = 'isListener';
  static const String fieldIsAvailable = 'isAvailable';

  static const String fieldFollowersCount = 'followersCount';
  static const String fieldLevel = 'level';
  static const String fieldListenerRate = 'listenerRate';

  static const String fieldFollowing = 'following';
  static const String fieldBlocked = 'blocked';
  static const String fieldFcmTokens = 'fcmTokens';
  static const String fieldFavoriteListeners = 'favoriteListeners';

  static const String fieldActiveCallId = 'activeCallId';
  static const String fieldActiveCallUpdatedAt = 'activeCallUpdatedAt';

  static const String fieldRatingAvg = 'ratingAvg';
  static const String fieldRatingCount = 'ratingCount';
  static const String fieldRatingSum = 'ratingSum';

  static const String fieldCreatedAt = 'createdAt';
  static const String fieldLastSeen = 'lastSeen';

  // ---------------- CALL FIELDS ----------------

  static const String fieldCallerId = 'callerId';
  static const String fieldCallerName = 'callerName';

  static const String fieldCalleeId = 'calleeId';
  static const String fieldCalleeName = 'calleeName';

  static const String fieldChannelId = 'channelId';

  static const String fieldAgoraTokenCaller = 'agoraTokenCaller';
  static const String fieldAgoraTokenCallee = 'agoraTokenCallee';

  static const String fieldStatus = 'status';

  static const String fieldSpeakerRate = 'speakerRate';

  /// Stored field is still `listenerRate`.
  static const String fieldListenerPayoutRate = 'listenerRate';

  /// Preferred alias for the same stored field.
  static const String fieldListenerRateValue = 'listenerRate';

  static const String fieldPlatformPercent = 'platformPercent';

  static const String fieldReservedUpfront = 'reservedUpfront';
  static const String fieldMaxPrepaidMinutes = 'maxPrepaidMinutes';
  static const String fieldPrepaidEndsAtMs = 'prepaidEndsAtMs';

  static const String fieldCreatedAtMs = 'createdAtMs';
  static const String fieldExpiresAtMs = 'expiresAtMs';

  static const String fieldStartedAt = 'startedAt';

  static const String fieldEndedAt = 'endedAt';
  static const String fieldEndedAtMs = 'endedAtMs';

  static const String fieldEndedBy = 'endedBy';
  static const String fieldEndedReason = 'endedReason';
  static const String fieldRejectedReason = 'rejectedReason';

  static const String fieldEndedSeconds = 'endedSeconds';

  static const String fieldReserveReleased = 'reserveReleased';
  static const String fieldReserveReleasedAt = 'reserveReleasedAt';

  static const String fieldSettled = 'settled';
  static const String fieldSettledAt = 'settledAt';

  static const String fieldListenerCredited = 'listenerCredited';
  static const String fieldListenerCreditedAt = 'listenerCreditedAt';

  static const String fieldSeconds = 'seconds';
  static const String fieldBilledMinutes = 'billedMinutes';
  static const String fieldPaidMinutes = 'paidMinutes';

  static const String fieldSpeakerCharge = 'speakerCharge';
  static const String fieldListenerPayout = 'listenerPayout';
  static const String fieldPlatformProfit = 'platformProfit';

  static const String fieldMissedCallPushSent = 'missedCallPushSent';
  static const String fieldMissedCallPushSentAt = 'missedCallPushSentAt';
  static const String fieldMissedCallPushSentAtMs = 'missedCallPushSentAtMs';

  static const String fieldIncomingPushAttempted = 'incomingPushAttempted';
  static const String fieldIncomingPushDelivered = 'incomingPushDelivered';
  static const String fieldIncomingPushSuccessCount =
      'incomingPushSuccessCount';
  static const String fieldIncomingPushFailureCount =
      'incomingPushFailureCount';

  static const String fieldIncomingPushAttemptedAt =
      'incomingPushAttemptedAt';
  static const String fieldIncomingPushAttemptedAtMs =
      'incomingPushAttemptedAtMs';

  static const String fieldIncomingPushNoTokens = 'incomingPushNoTokens';
  static const String fieldIncomingPushError = 'incomingPushError';

  static const String fieldCancelSignalSent = 'cancelSignalSent';
  static const String fieldCancelSignalSentAt = 'cancelSignalSentAt';
  static const String fieldCancelSignalSentAtMs = 'cancelSignalSentAtMs';

  static const String fieldSettlementVersion = 'settlementVersion';
  static const String fieldSettlementIdempotencyKey =
      'settlementIdempotencyKey';
  static const String fieldReserveReleaseIdempotencyKey =
      'reserveReleaseIdempotencyKey';
  static const String fieldCallerChargeTxId = 'callerChargeTxId';
  static const String fieldListenerPayoutTxId = 'listenerPayoutTxId';
  static const String fieldPlatformRevenueTxId = 'platformRevenueTxId';
  static const String fieldRefundTxId = 'refundTxId';
  static const String fieldCurrency = 'currency';
  static const String fieldGatewayContext = 'gatewayContext';
  static const String fieldSettlementSource = 'settlementSource';

  // ---------------- CHAT SESSION FIELDS ----------------

  static const String fieldChatSessionId = 'sessionId';

  static const String fieldSpeakerId = 'speakerId';
  static const String fieldListenerId = 'listenerId';

  static const String fieldChatCreatedAt = 'createdAt';
  static const String fieldChatUpdatedAt = 'updatedAt';
  static const String fieldChatCreatedAtMs = 'createdAtMs';
  static const String fieldChatUpdatedAtMs = 'updatedAtMs';

  static const String fieldChatStatus = 'status';
  static const String fieldCallAllowed = 'callAllowed';

  static const String fieldSpeakerBlocked = 'speakerBlocked';
  static const String fieldListenerBlocked = 'listenerBlocked';

  static const String fieldCallRequestedBy = 'callRequestedBy';
  static const String fieldCallRequestOpen = 'callRequestOpen';
  static const String fieldCallRequestAt = 'callRequestAt';
  static const String fieldCallRequestAtMs = 'callRequestAtMs';

  static const String fieldCallAllowedAt = 'callAllowedAt';
  static const String fieldCallAllowedAtMs = 'callAllowedAtMs';

  static const String fieldLastMessageText = 'lastMessageText';
  static const String fieldLastMessageSenderId = 'lastMessageSenderId';
  static const String fieldLastMessageType = 'lastMessageType';
  static const String fieldLastMessageAt = 'lastMessageAt';
  static const String fieldLastMessageAtMs = 'lastMessageAtMs';

  static const String fieldSpeakerUnreadCount = 'speakerUnreadCount';
  static const String fieldListenerUnreadCount = 'listenerUnreadCount';

  static const String fieldChatClosedAt = 'closedAt';
  static const String fieldChatClosedAtMs = 'closedAtMs';
  static const String fieldChatClosedBy = 'closedBy';
  static const String fieldChatArchived = 'archived';

  // ---------------- CHAT MESSAGE FIELDS ----------------

  static const String fieldMessageId = 'messageId';
  static const String fieldMessageText = 'text';
  static const String fieldMessageType = 'type';
  static const String fieldMessageSenderId = 'senderId';
  static const String fieldMessageReceiverId = 'receiverId';
  static const String fieldMessageCreatedAt = 'createdAt';
  static const String fieldMessageCreatedAtMs = 'createdAtMs';
  static const String fieldMessageSeen = 'seen';
  static const String fieldMessageSeenAt = 'seenAt';
  static const String fieldMessageSeenAtMs = 'seenAtMs';
  static const String fieldMessageSystemAction = 'systemAction';
  static const String fieldMessageMetadata = 'metadata';

  // ---------------- REVIEW FIELDS ----------------

  static const String fieldCallId = 'callId';
  static const String fieldReviewerId = 'reviewerId';
  static const String fieldReviewedUserId = 'reviewedUserId';
  static const String fieldStars = 'stars';
  static const String fieldComment = 'comment';

  // ---------------- REPORT FIELDS ----------------

  static const String fieldReporterId = 'reporterId';
  static const String fieldReason = 'reason';

  // ---------------- WALLET TRANSACTION FIELDS ----------------

  static const String fieldTransactionUserId = 'userId';
  static const String fieldTransactionType = 'type';
  static const String fieldTransactionAmount = 'amount';
  static const String fieldTransactionBalanceAfter = 'balanceAfter';
  static const String fieldTransactionMethod = 'method';
  static const String fieldTransactionNotes = 'notes';
  static const String fieldTransactionCreatedAt = 'createdAt';
  static const String fieldTransactionStatus = 'status';

  static const String fieldTransactionDirection = 'direction';
  static const String fieldTransactionCallId = 'callId';
  static const String fieldTransactionPaymentOrderId = 'paymentOrderId';
  static const String fieldTransactionPaymentId = 'paymentId';
  static const String fieldTransactionWithdrawalRequestId =
      'withdrawalRequestId';
  static const String fieldTransactionSource = 'source';
  static const String fieldTransactionIdempotencyKey = 'idempotencyKey';
  static const String fieldTransactionCurrency = 'currency';
  static const String fieldTransactionGateway = 'gateway';
  static const String fieldTransactionMetadata = 'metadata';

  // ---------------- WITHDRAWAL REQUEST FIELDS ----------------

  static const String fieldWithdrawalUserId = 'userId';
  static const String fieldWithdrawalUserName = 'userName';
  static const String fieldWithdrawalAmount = 'amount';
  static const String fieldWithdrawalNote = 'note';
  static const String fieldWithdrawalPayoutMode = 'payoutMode';
  static const String fieldWithdrawalRealMoneyEnabled = 'realMoneyEnabled';
  static const String fieldWithdrawalEarningsSnapshot = 'earningsSnapshot';
  static const String fieldWithdrawalRequestedAt = 'requestedAt';
  static const String fieldWithdrawalRequestedAtMs = 'requestedAtMs';
  static const String fieldWithdrawalUpdatedAt = 'updatedAt';
  static const String fieldWithdrawalUpdatedAtMs = 'updatedAtMs';
  static const String fieldWithdrawalCancelledAt = 'cancelledAt';
  static const String fieldWithdrawalCancelledAtMs = 'cancelledAtMs';
  static const String fieldWithdrawalCancelledBy = 'cancelledBy';

  static const String fieldWithdrawalStatusReason = 'statusReason';
  static const String fieldWithdrawalApprovedAt = 'approvedAt';
  static const String fieldWithdrawalApprovedBy = 'approvedBy';
  static const String fieldWithdrawalRejectedAt = 'rejectedAt';
  static const String fieldWithdrawalRejectedBy = 'rejectedBy';
  static const String fieldWithdrawalPaidAt = 'paidAt';
  static const String fieldWithdrawalPaidBy = 'paidBy';
  static const String fieldWithdrawalPaymentReference = 'paymentReference';
  static const String fieldWithdrawalLedgerTransactionId =
      'ledgerTransactionId';
  static const String fieldWithdrawalIdempotencyKey = 'idempotencyKey';
  static const String fieldWithdrawalCurrency = 'currency';
  static const String fieldWithdrawalAdminNote = 'adminNote';
  static const String fieldWithdrawalPayoutAccountSnapshot =
      'payoutAccountSnapshot';

  // ---------------- PAYMENT ORDER FIELDS ----------------

  static const String fieldPaymentOrderUserId = 'userId';
  static const String fieldPaymentOrderGateway = 'gateway';
  static const String fieldPaymentOrderOrderId = 'orderId';
  static const String fieldPaymentOrderPaymentId = 'paymentId';
  static const String fieldPaymentOrderAmount = 'amount';
  static const String fieldPaymentOrderCurrency = 'currency';
  static const String fieldPaymentOrderStatus = 'status';
  static const String fieldPaymentOrderCreatedAt = 'createdAt';
  static const String fieldPaymentOrderVerifiedAt = 'verifiedAt';
  static const String fieldPaymentOrderFailureReason = 'failureReason';
  static const String fieldPaymentOrderIdempotencyKey = 'idempotencyKey';
  static const String fieldPaymentOrderMetadata = 'metadata';

  // ---------------- WALLET LOCK FIELDS ----------------

  static const String fieldWalletLockType = 'lockType';
  static const String fieldWalletLockResourceId = 'resourceId';
  static const String fieldWalletLockCreatedAt = 'createdAt';
  static const String fieldWalletLockExpiresAt = 'expiresAt';
  static const String fieldWalletLockOwner = 'owner';

  // ---------------- STATUS VALUES ----------------

  static const String statusRinging = 'ringing';
  static const String statusAccepted = 'accepted';
  static const String statusEnded = 'ended';
  static const String statusRejected = 'rejected';

  // Chat statuses
  static const String chatStatusNone = 'none';
  static const String chatStatusPending = 'pending';
  static const String chatStatusAccepted = 'accepted';
  static const String chatStatusActive = 'active';
  static const String chatStatusBlocked = 'blocked';
  static const String chatStatusClosed = 'closed';

  // Chat message types
  static const String messageTypeText = 'text';
  static const String messageTypeSystem = 'system';
  static const String messageTypeAccessRequest = 'access_request';
  static const String messageTypeAccessApproved = 'access_approved';
  static const String messageTypeAccessDenied = 'access_denied';

  // Backward-compatible / commonly used call-event chat message aliases
  static const String messageTypeCallStart = 'call_start';
  static const String messageTypeCallEnd = 'call_end';
  static const String messageTypeMissedCall = 'missed_call';
  static const String messageTypeCallCharge = 'call_charge';

  // ---------------- WALLET TRANSACTION TYPES ----------------

  static const String txTypeCallCharge = 'call_charge';
  static const String txTypeCallEarning = 'call_earning';
  static const String txTypeTopup = 'topup';
  static const String txTypeWithdrawal = 'withdrawal';
  static const String txTypeRefund = 'refund';

  static const String txTypeCallReserveHold = 'call_reserve_hold';
  static const String txTypeCallReserveRelease = 'call_reserve_release';
  static const String txTypeWithdrawalRequest = 'withdrawal_request';
  static const String txTypeWithdrawalPaid = 'withdrawal_paid';
  static const String txTypeWithdrawalRejected = 'withdrawal_rejected';
  static const String txTypeWithdrawalCancelled = 'withdrawal_cancelled';
  static const String txTypeAdminAdjustmentCredit = 'admin_adjustment_credit';
  static const String txTypeAdminAdjustmentDebit = 'admin_adjustment_debit';

  // ---------------- WALLET TRANSACTION DIRECTIONS ----------------

  static const String txDirectionCredit = 'credit';
  static const String txDirectionDebit = 'debit';

  // ---------------- WALLET TRANSACTION SOURCES ----------------

  static const String txSourceGateway = 'gateway';
  static const String txSourceSettlement = 'settlement';
  static const String txSourceSystem = 'system';
  static const String txSourceAdmin = 'admin';

  // ---------------- PAYMENT GATEWAYS ----------------

  static const String gatewayRazorpay = 'razorpay';
  static const String gatewayStripe = 'stripe';

  // ---------------- WITHDRAWAL STATUS VALUES ----------------

  static const String withdrawalStatusPending = 'pending';
  static const String withdrawalStatusApproved = 'approved';
  static const String withdrawalStatusRejected = 'rejected';
  static const String withdrawalStatusCancelled = 'cancelled';
  static const String withdrawalStatusPaid = 'paid';

  // ---------------- PAYMENT ORDER STATUS VALUES ----------------

  static const String paymentOrderStatusCreated = 'created';
  static const String paymentOrderStatusPending = 'pending';
  static const String paymentOrderStatusVerified = 'verified';
  static const String paymentOrderStatusFailed = 'failed';
  static const String paymentOrderStatusCancelled = 'cancelled';

  // ---------------- WALLET LOCK TYPES ----------------

  static const String walletLockTypeCallSettlement = 'call_settlement';
  static const String walletLockTypeReserveRelease = 'reserve_release';
  static const String walletLockTypeTopupVerification = 'topup_verification';
  static const String walletLockTypeWithdrawalProcessing =
      'withdrawal_processing';

  // ---------------- CALL END REASONS ----------------

  static const String reasonTimeout = 'timeout';
  static const String reasonBusy = 'busy';
  static const String reasonInvalid = 'invalid';

  static const String reasonServerTimeout = 'server_timeout';

  static const String reasonCallerCancel = 'caller_cancel';
  static const String reasonCallerTimeout = 'caller_timeout';
  static const String reasonCallerTimeoutCleanup = 'caller_timeout_cleanup';

  static const String reasonCalleeReject = 'callee_reject';
  static const String reasonCalleeRejectCallkit = 'callee_reject_callkit';

  static const String reasonCallkitEnded = 'callkit_ended';

  static const String reasonRemoteLeft = 'remote_left';
  static const String reasonConnectionLost = 'connection_lost';

  static const String reasonUserEnd = 'user_end';

  static const String reasonBackPressed = 'back_pressed';
  static const String reasonAppDetached = 'app_detached';

  static const String reasonStaleTimeout = 'stale_timeout';
  static const String reasonCreditLimitReached = 'credit_limit_reached';
}