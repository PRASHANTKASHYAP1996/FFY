const {
  admin,
  functions,
  REGION,
  intOr,
  strOr,
  boolOr,
  assertCallableAppCheck,
} = require("./shared");
const { requireAdmin } = require("./admin");

const ANALYTICS_CACHE_ROOT = "analytics_cache";
const SUMMARY_TTL_MS = 2 * 60 * 1000;
const TODAY_TTL_MS = 2 * 60 * 1000;
const RETENTION_TTL_MS = 10 * 60 * 1000;
const TIMESERIES_TTL_MS = 10 * 60 * 1000;
const LEADERBOARD_TTL_MS = 10 * 60 * 1000;

const SUMMARY_ENDED_SAMPLE_LIMIT = 3000;
const SUMMARY_REJECTED_SAMPLE_LIMIT = 2000;
const RETENTION_CALL_SAMPLE_LIMIT = 5000;
const LEADERBOARD_CALL_SAMPLE_LIMIT = 5000;

function asDate(value) {
  if (!value) return null;

  try {
    if (typeof value.toDate === "function") {
      return value.toDate();
    }
  } catch (_) {}

  if (value instanceof Date) return value;

  return null;
}

function dayKeyFromDate(dt) {
  const y = String(dt.getFullYear()).padStart(4, "0");
  const m = String(dt.getMonth() + 1).padStart(2, "0");
  const d = String(dt.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

function shortDayLabel(dt) {
  const days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  return days[dt.getDay()];
}

function startOfDay(dt) {
  return new Date(dt.getFullYear(), dt.getMonth(), dt.getDate());
}

function addDays(dt, days) {
  const copy = new Date(dt);
  copy.setDate(copy.getDate() + days);
  return copy;
}

function bestUserCreatedAt(user) {
  return asDate(user.createdAt) || asDate(user.lastSeen);
}

function bestCallDate(call) {
  return (
    asDate(call.endedAt) ||
    asDate(call.startedAt) ||
    asDate(call.createdAt) ||
    (intOr(call.createdAtMs) > 0 ? new Date(intOr(call.createdAtMs)) : null)
  );
}

function bestTransactionDate(tx) {
  return (
    asDate(tx.transactionCreatedAt) ||
    asDate(tx.createdAt) ||
    (intOr(tx.createdAtMs) > 0 ? new Date(intOr(tx.createdAtMs)) : null)
  );
}

function bestWithdrawalDate(withdrawal) {
  return (
    asDate(withdrawal.requestedAt) ||
    asDate(withdrawal.createdAt) ||
    (intOr(withdrawal.requestedAtMs) > 0
      ? new Date(intOr(withdrawal.requestedAtMs))
      : null)
  );
}

function bestCallSeconds(call) {
  const endedSeconds = intOr(call.endedSeconds);
  if (endedSeconds > 0) return endedSeconds;

  const seconds = intOr(call.seconds);
  if (seconds > 0) return seconds;

  return 0;
}

function isPaidCall(call) {
  return intOr(call.speakerCharge) > 0 || intOr(call.listenerPayout) > 0;
}

function wasAnswered(call) {
  if (call.startedAt) return true;
  if (strOr(call.status) === "accepted") return true;
  if (bestCallSeconds(call) > 0) return true;
  if (isPaidCall(call)) return true;

  const endedReason = strOr(call.endedReason).trim().toLowerCase();
  const rejectedReason = strOr(call.rejectedReason).trim().toLowerCase();

  const nonAnsweredReasons = new Set([
    "timeout",
    "busy",
    "caller_cancel",
    "caller_cancelled",
    "callee_reject",
    "callee_reject_callkit",
    "callkit_ended",
    "invalid",
    "open_call_failed",
    "invalid_channel",
    "caller_timeout",
    "caller_timeout_cleanup",
    "server_timeout",
    "stale_timeout",
    "missed",
    "no_answer",
  ]);

  if (nonAnsweredReasons.has(endedReason)) return false;
  if (nonAnsweredReasons.has(rejectedReason)) return false;
  if (strOr(call.status) === "rejected") return false;

  return (
    strOr(call.status) === "ended" &&
    (bestCallSeconds(call) > 0 || isPaidCall(call))
  );
}

function isFreeAnsweredCall(call) {
  return wasAnswered(call) && !isPaidCall(call);
}

function analyticsCacheRef(docId) {
  return admin
    .firestore()
    .collection("system")
    .doc(ANALYTICS_CACHE_ROOT)
    .collection("docs")
    .doc(docId);
}

async function readFreshCacheOrNull(docId, maxAgeMs) {
  const snap = await analyticsCacheRef(docId).get();
  if (!snap.exists) return null;

  const data = snap.data() || {};
  const refreshedAtMs = intOr(data.refreshedAtMs, 0);
  if (refreshedAtMs <= 0) return null;

  if (Date.now() - refreshedAtMs > maxAgeMs) {
    return null;
  }

  return data.payload || null;
}

async function writeCache(docId, payload) {
  await analyticsCacheRef(docId).set(
    {
      refreshedAt: admin.firestore.FieldValue.serverTimestamp(),
      refreshedAtMs: Date.now(),
      payload,
    },
    { merge: true }
  );
}

async function safeCount(query) {
  try {
    const snap = await query.count().get();
    return intOr(snap.data().count, 0);
  } catch (_) {
    const fallback = await query.get();
    return fallback.size;
  }
}

async function fetchCallsInWindow({ fromDate, toDateExclusive }) {
  const db = admin.firestore();
  const out = [];

  const queries = [
    db
      .collection("calls")
      .where("createdAt", ">=", fromDate)
      .where("createdAt", "<", toDateExclusive),
    db
      .collection("calls")
      .where("endedAt", ">=", fromDate)
      .where("endedAt", "<", toDateExclusive),
  ];

  const seen = new Set();

  for (const query of queries) {
    const snap = await query.get();
    for (const doc of snap.docs) {
      if (seen.has(doc.id)) continue;
      seen.add(doc.id);
      out.push({ id: doc.id, ...doc.data() });
    }
  }

  return out;
}

async function fetchUsersCreatedInWindow({ fromDate, toDateExclusive }) {
  const db = admin.firestore();
  const snap = await db
    .collection("users")
    .where("createdAt", ">=", fromDate)
    .where("createdAt", "<", toDateExclusive)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function fetchWalletTransactionsInWindow({ fromDate, toDateExclusive }) {
  const db = admin.firestore();
  const snap = await db
    .collection("wallet_transactions")
    .where("createdAt", ">=", fromDate)
    .where("createdAt", "<", toDateExclusive)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function fetchWithdrawalsInWindow({ fromDate, toDateExclusive }) {
  const db = admin.firestore();
  const snap = await db
    .collection("withdrawal_requests")
    .where("requestedAt", ">=", fromDate)
    .where("requestedAt", "<", toDateExclusive)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function fetchRecentReviews({ limit = 500 }) {
  const db = admin.firestore();
  const snap = await db
    .collection("reviews")
    .orderBy("createdAt", "desc")
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function fetchAllListeners() {
  const db = admin.firestore();
  const snap = await db
    .collection("users")
    .where("isListener", "==", true)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

function buildCoverageMeta({
  mode,
  sampledCalls = 0,
  sampledEndedCalls = 0,
  sampledRejectedCalls = 0,
  limits = {},
}) {
  return {
    mode,
    sampledCalls,
    sampledEndedCalls,
    sampledRejectedCalls,
    limits: {
      ended: intOr(limits.ended, 0),
      rejected: intOr(limits.rejected, 0),
      total: intOr(limits.total, 0),
    },
    sampled: mode !== "full_window",
    authoritativeMoneyTotals: false,
    authoritativeAnsweredMissedTotals: false,
  };
}

function mergeTruthFlags(overrides = {}) {
  return {
    summaryUsesSampledCalls: false,
    retentionUsesSampledCalls: false,
    leaderboardUsesSampledCalls: false,
    todayUsesWindowQueries: true,
    timeseriesUsesWindowQueries: true,
    authoritativeMoneyTotals: false,
    authoritativeAnsweredMissedTotals: false,
    ...overrides,
  };
}

async function buildSummaryPayload() {
  const db = admin.firestore();

  const [
    totalUsers,
    totalListeners,
    availableListeners,
    totalCalls,
    ringingCalls,
    acceptedCalls,
    endedCalls,
    rejectedCalls,
    totalWalletTransactions,
    totalWithdrawalRequests,
    pendingWithdrawalRequests,
    recentReviews,
  ] = await Promise.all([
    safeCount(db.collection("users")),
    safeCount(db.collection("users").where("isListener", "==", true)),
    safeCount(
      db.collection("users")
        .where("isListener", "==", true)
        .where("isAvailable", "==", true)
    ),
    safeCount(db.collection("calls")),
    safeCount(db.collection("calls").where("status", "==", "ringing")),
    safeCount(db.collection("calls").where("status", "==", "accepted")),
    safeCount(db.collection("calls").where("status", "==", "ended")),
    safeCount(db.collection("calls").where("status", "==", "rejected")),
    safeCount(db.collection("wallet_transactions")),
    safeCount(db.collection("withdrawal_requests")),
    safeCount(
      db.collection("withdrawal_requests").where("status", "==", "pending")
    ),
    fetchRecentReviews({ limit: 1000 }),
  ]);

  const recentEndedCalls = await db
    .collection("calls")
    .where("status", "==", "ended")
    .orderBy("endedAt", "desc")
    .limit(SUMMARY_ENDED_SAMPLE_LIMIT)
    .get();

  const recentRejectedCalls = await db
    .collection("calls")
    .where("status", "==", "rejected")
    .orderBy("endedAt", "desc")
    .limit(SUMMARY_REJECTED_SAMPLE_LIMIT)
    .get();

  const calls = [
    ...recentEndedCalls.docs.map((d) => ({ id: d.id, ...d.data() })),
    ...recentRejectedCalls.docs.map((d) => ({ id: d.id, ...d.data() })),
  ];

  let answeredCalls = 0;
  let missedCalls = 0;
  let paidCalls = 0;
  let freeCallsUnder60 = 0;
  let totalSpeakerCharge = 0;
  let totalListenerPayout = 0;
  let totalPlatformProfit = 0;

  for (const call of calls) {
    const answered = wasAnswered(call);
    const speakerCharge = intOr(call.speakerCharge);
    const listenerPayout = intOr(call.listenerPayout);
    const platformProfit = intOr(call.platformProfit);

    if (answered) {
      answeredCalls += 1;
      if (isPaidCall(call)) {
        paidCalls += 1;
      } else if (isFreeAnsweredCall(call)) {
        freeCallsUnder60 += 1;
      }
    } else {
      missedCalls += 1;
    }

    totalSpeakerCharge += speakerCharge;
    totalListenerPayout += listenerPayout;
    totalPlatformProfit += platformProfit;
  }

  let reviewSum = 0;
  for (const review of recentReviews) {
    reviewSum += Number(review.stars || 0);
  }

  const totalReviews = recentReviews.length;
  const averageReviewStars = totalReviews > 0 ? reviewSum / totalReviews : 0;

  return {
    totalUsers,
    totalListeners,
    availableListeners,
    totalCalls,
    ringingCalls,
    acceptedCalls,
    endedCalls,
    rejectedCalls,
    answeredCalls,
    missedCalls,
    paidCalls,
    freeCallsUnder60,
    totalSpeakerCharge,
    totalListenerPayout,
    totalPlatformProfit,
    totalReviews,
    averageReviewStars,
    totalWalletTransactions,
    totalWithdrawalRequests,
    pendingWithdrawalRequests,
    coverage: buildCoverageMeta({
      mode: "recent_sample",
      sampledCalls: calls.length,
      sampledEndedCalls: recentEndedCalls.size,
      sampledRejectedCalls: recentRejectedCalls.size,
      limits: {
        ended: SUMMARY_ENDED_SAMPLE_LIMIT,
        rejected: SUMMARY_REJECTED_SAMPLE_LIMIT,
        total: SUMMARY_ENDED_SAMPLE_LIMIT + SUMMARY_REJECTED_SAMPLE_LIMIT,
      },
    }),
    truthFlags: mergeTruthFlags({
      summaryUsesSampledCalls: true,
      authoritativeMoneyTotals: false,
      authoritativeAnsweredMissedTotals: false,
    }),
    generatedAtMs: Date.now(),
  };
}

async function buildTodaySummaryPayload() {
  const now = new Date();
  const today = startOfDay(now);
  const tomorrow = addDays(today, 1);
  const todayKey = dayKeyFromDate(today);

  const [users, calls, walletTransactions, withdrawals] = await Promise.all([
    fetchUsersCreatedInWindow({
      fromDate: today,
      toDateExclusive: tomorrow,
    }),
    fetchCallsInWindow({
      fromDate: today,
      toDateExclusive: tomorrow,
    }),
    fetchWalletTransactionsInWindow({
      fromDate: today,
      toDateExclusive: tomorrow,
    }),
    fetchWithdrawalsInWindow({
      fromDate: today,
      toDateExclusive: tomorrow,
    }),
  ]);

  let totalCalls = 0;
  let answeredCalls = 0;
  let missedCalls = 0;
  let paidCalls = 0;
  let freeAnsweredCalls = 0;
  let totalSpeakerCharge = 0;
  let totalListenerPayout = 0;
  let totalPlatformProfit = 0;

  for (const call of calls) {
    totalCalls += 1;

    const answered = wasAnswered(call);
    const speakerCharge = intOr(call.speakerCharge);
    const listenerPayout = intOr(call.listenerPayout);
    const platformProfit = intOr(call.platformProfit);

    if (answered) {
      answeredCalls += 1;
      if (isPaidCall(call)) {
        paidCalls += 1;
      } else if (isFreeAnsweredCall(call)) {
        freeAnsweredCalls += 1;
      }
    } else {
      missedCalls += 1;
    }

    totalSpeakerCharge += speakerCharge;
    totalListenerPayout += listenerPayout;
    totalPlatformProfit += platformProfit;
  }

  let pendingWithdrawalRequests = 0;
  for (const withdrawal of withdrawals) {
    const primaryStatus = strOr(withdrawal.transactionStatus).toLowerCase();
    const fallbackStatus = strOr(withdrawal.status, "pending").toLowerCase();
    const status = primaryStatus || fallbackStatus;

    if (status === "pending") {
      pendingWithdrawalRequests += 1;
    }
  }

  return {
    dayKey: todayKey,
    newUsers: users.length,
    totalCalls,
    answeredCalls,
    missedCalls,
    paidCalls,
    freeAnsweredCalls,
    totalSpeakerCharge,
    totalListenerPayout,
    totalPlatformProfit,
    walletTransactions: walletTransactions.length,
    withdrawalRequests: withdrawals.length,
    pendingWithdrawalRequests,
    coverage: {
      mode: "full_window",
      windowStartMs: today.getTime(),
      windowEndExclusiveMs: tomorrow.getTime(),
      sampled: false,
      authoritativeMoneyTotals: true,
      authoritativeAnsweredMissedTotals: true,
    },
    truthFlags: mergeTruthFlags({
      todayUsesWindowQueries: true,
      authoritativeMoneyTotals: true,
      authoritativeAnsweredMissedTotals: true,
    }),
    generatedAtMs: Date.now(),
  };
}

async function buildRetentionSummaryPayload() {
  const db = admin.firestore();
  const callsSnap = await db
    .collection("calls")
    .where("status", "in", ["ended", "rejected"])
    .limit(RETENTION_CALL_SAMPLE_LIMIT)
    .get();

  const calls = callsSnap.docs.map((d) => d.data() || {});

  const callerCounts = {};
  const listenerCounts = {};
  const userCounts = {};
  const pairMap = {};

  for (const call of calls) {
    const callerId = strOr(call.callerId);
    const callerName = strOr(call.callerName, "Caller");
    const listenerId = strOr(call.calleeId);
    const listenerName = strOr(call.calleeName, "Listener");

    if (!callerId || !listenerId) continue;

    const answered = wasAnswered(call);
    const isPaid = isPaidCall(call);

    callerCounts[callerId] = intOr(callerCounts[callerId]) + 1;
    listenerCounts[listenerId] = intOr(listenerCounts[listenerId]) + 1;
    userCounts[callerId] = intOr(userCounts[callerId]) + 1;
    userCounts[listenerId] = intOr(userCounts[listenerId]) + 1;

    const pairKey = `${callerId}::${listenerId}`;
    const existing = pairMap[pairKey];

    if (!existing) {
      pairMap[pairKey] = {
        callerId,
        callerName,
        listenerId,
        listenerName,
        totalCalls: 1,
        answeredCalls: answered ? 1 : 0,
        paidCalls: isPaid ? 1 : 0,
      };
    } else {
      pairMap[pairKey] = {
        callerId: existing.callerId,
        callerName: existing.callerName,
        listenerId: existing.listenerId,
        listenerName: existing.listenerName,
        totalCalls: intOr(existing.totalCalls) + 1,
        answeredCalls: intOr(existing.answeredCalls) + (answered ? 1 : 0),
        paidCalls: intOr(existing.paidCalls) + (isPaid ? 1 : 0),
      };
    }
  }

  const repeatCallers = Object.values(callerCounts).filter(
    (v) => intOr(v) >= 2
  ).length;
  const repeatListeners = Object.values(listenerCounts).filter(
    (v) => intOr(v) >= 2
  ).length;
  const usersWithMultipleCalls = Object.values(userCounts).filter(
    (v) => intOr(v) >= 2
  ).length;

  const repeatPairs = Object.values(pairMap).filter(
    (pair) => intOr(pair.totalCalls) >= 2
  );

  const topRepeatPairs = [...repeatPairs]
    .sort((a, b) => {
      const totalCompare = intOr(b.totalCalls) - intOr(a.totalCalls);
      if (totalCompare !== 0) return totalCompare;

      const answeredCompare =
        intOr(b.answeredCalls) - intOr(a.answeredCalls);
      if (answeredCompare !== 0) return answeredCompare;

      return intOr(b.paidCalls) - intOr(a.paidCalls);
    })
    .slice(0, 10);

  return {
    uniqueCallers: Object.keys(callerCounts).length,
    uniqueListeners: Object.keys(listenerCounts).length,
    repeatCallers,
    repeatListeners,
    usersWithMultipleCalls,
    repeatPairsCount: repeatPairs.length,
    topRepeatPairs,
    coverage: {
      mode: "recent_sample",
      sampled: true,
      sampledCalls: calls.length,
      sampleLimit: RETENTION_CALL_SAMPLE_LIMIT,
      authoritative: false,
    },
    truthFlags: mergeTruthFlags({
      retentionUsesSampledCalls: true,
    }),
    generatedAtMs: Date.now(),
  };
}

async function buildLast7DaysTimeseriesPayload() {
  const now = new Date();
  const today = startOfDay(now);
  const fromDate = addDays(today, -6);
  const toDateExclusive = addDays(today, 1);

  const [users, calls] = await Promise.all([
    fetchUsersCreatedInWindow({
      fromDate,
      toDateExclusive,
    }),
    fetchCallsInWindow({
      fromDate,
      toDateExclusive,
    }),
  ]);

  const dayOrder = [];
  const bucket = {};

  for (let i = 6; i >= 0; i--) {
    const day = addDays(today, -i);
    const key = dayKeyFromDate(day);
    dayOrder.push(day);
    bucket[key] = {
      newUsers: 0,
      totalCalls: 0,
      answeredCalls: 0,
      missedCalls: 0,
      paidCalls: 0,
      totalSpeakerCharge: 0,
      totalListenerPayout: 0,
      totalPlatformProfit: 0,
    };
  }

  for (const user of users) {
    const createdAt = bestUserCreatedAt(user);
    if (!createdAt) continue;

    const key = dayKeyFromDate(createdAt);
    if (!bucket[key]) continue;
    bucket[key].newUsers += 1;
  }

  for (const call of calls) {
    const date = bestCallDate(call);
    if (!date) continue;

    const key = dayKeyFromDate(date);
    if (!bucket[key]) continue;

    const answered = wasAnswered(call);
    const speakerCharge = intOr(call.speakerCharge);
    const listenerPayout = intOr(call.listenerPayout);
    const platformProfit = intOr(call.platformProfit);
    const isPaid = isPaidCall(call);

    bucket[key].totalCalls += 1;
    if (answered) {
      bucket[key].answeredCalls += 1;
    } else {
      bucket[key].missedCalls += 1;
    }
    if (isPaid) {
      bucket[key].paidCalls += 1;
    }

    bucket[key].totalSpeakerCharge += speakerCharge;
    bucket[key].totalListenerPayout += listenerPayout;
    bucket[key].totalPlatformProfit += platformProfit;
  }

  const points = dayOrder.map((day) => {
    const key = dayKeyFromDate(day);
    const map = bucket[key] || {};
    return {
      dayKey: key,
      shortLabel: shortDayLabel(day),
      newUsers: intOr(map.newUsers),
      totalCalls: intOr(map.totalCalls),
      answeredCalls: intOr(map.answeredCalls),
      missedCalls: intOr(map.missedCalls),
      paidCalls: intOr(map.paidCalls),
      totalSpeakerCharge: intOr(map.totalSpeakerCharge),
      totalListenerPayout: intOr(map.totalListenerPayout),
      totalPlatformProfit: intOr(map.totalPlatformProfit),
    };
  });

  return {
    points,
    coverage: {
      mode: "full_window",
      windowStartMs: fromDate.getTime(),
      windowEndExclusiveMs: toDateExclusive.getTime(),
      sampled: false,
      authoritativeMoneyTotals: true,
      authoritativeAnsweredMissedTotals: true,
    },
    truthFlags: mergeTruthFlags({
      timeseriesUsesWindowQueries: true,
      authoritativeMoneyTotals: true,
      authoritativeAnsweredMissedTotals: true,
    }),
    generatedAtMs: Date.now(),
  };
}

async function buildListenerLeaderboardPayload() {
  const [listeners, endedCalls] = await Promise.all([
    fetchAllListeners(),
    (async () => {
      const db = admin.firestore();
      const snap = await db
        .collection("calls")
        .where("status", "==", "ended")
        .orderBy("endedAt", "desc")
        .limit(LEADERBOARD_CALL_SAMPLE_LIMIT)
        .get();

      return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
    })(),
  ]);

  const earnedByListener = {};
  const paidCallsByListener = {};

  for (const call of endedCalls) {
    const calleeId = strOr(call.calleeId);
    if (!calleeId) continue;

    const listenerPayout = intOr(call.listenerPayout);
    if (listenerPayout > 0) {
      earnedByListener[calleeId] =
        intOr(earnedByListener[calleeId]) + listenerPayout;
      paidCallsByListener[calleeId] =
        intOr(paidCallsByListener[calleeId]) + 1;
    }
  }

  const items = listeners.map((user) => {
    const uid = strOr(user.uid, user.id);
    const displayName =
      strOr(user.displayName) ||
      (strOr(user.email).includes("@")
        ? strOr(user.email).split("@")[0]
        : "Listener");

    return {
      uid,
      displayName,
      followersCount: intOr(user.followersCount),
      ratingAvg: Number(user.ratingAvg || 0),
      ratingCount: intOr(user.ratingCount),
      totalEarned: intOr(earnedByListener[uid]),
      paidCalls: intOr(paidCallsByListener[uid]),
      isAvailable: boolOr(user.isAvailable),
    };
  });

  return {
    items,
    coverage: {
      mode: "recent_sample",
      sampled: true,
      sampledCalls: endedCalls.length,
      sampleLimit: LEADERBOARD_CALL_SAMPLE_LIMIT,
      authoritative: false,
    },
    truthFlags: mergeTruthFlags({
      leaderboardUsesSampledCalls: true,
    }),
    generatedAtMs: Date.now(),
  };
}

async function getOrBuildCachedPayload({
  cacheKey,
  ttlMs,
  build,
  forceRefresh = false,
}) {
  if (!forceRefresh) {
    const cached = await readFreshCacheOrNull(cacheKey, ttlMs);
    if (cached) return cached;
  }

  const payload = await build();
  await writeCache(cacheKey, payload);
  return payload;
}

exports.analyticsLoadSummary_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "analyticsLoadSummary_v1");

    await requireAdmin(context);

    const forceRefresh = boolOr(data && data.forceRefresh, false);

    return getOrBuildCachedPayload({
      cacheKey: "summary_v1",
      ttlMs: SUMMARY_TTL_MS,
      forceRefresh,
      build: async () => buildSummaryPayload(),
    });
  });

exports.analyticsLoadTodaySummary_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "analyticsLoadTodaySummary_v1");

    await requireAdmin(context);

    const forceRefresh = boolOr(data && data.forceRefresh, false);

    return getOrBuildCachedPayload({
      cacheKey: "today_summary_v1",
      ttlMs: TODAY_TTL_MS,
      forceRefresh,
      build: async () => buildTodaySummaryPayload(),
    });
  });

exports.analyticsLoadRetentionSummary_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "analyticsLoadRetentionSummary_v1");

    await requireAdmin(context);

    const forceRefresh = boolOr(data && data.forceRefresh, false);

    return getOrBuildCachedPayload({
      cacheKey: "retention_summary_v1",
      ttlMs: RETENTION_TTL_MS,
      forceRefresh,
      build: async () => buildRetentionSummaryPayload(),
    });
  });

exports.analyticsLoadLast7DaysTimeseries_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "analyticsLoadLast7DaysTimeseries_v1");

    await requireAdmin(context);

    const forceRefresh = boolOr(data && data.forceRefresh, false);

    return getOrBuildCachedPayload({
      cacheKey: "last7days_timeseries_v1",
      ttlMs: TIMESERIES_TTL_MS,
      forceRefresh,
      build: async () => buildLast7DaysTimeseriesPayload(),
    });
  });

exports.analyticsLoadListenerLeaderboard_v1 = functions
  .region(REGION)
  .https.onCall(async (data, context) => {
    assertCallableAppCheck(context, "analyticsLoadListenerLeaderboard_v1");

    await requireAdmin(context);

    const forceRefresh = boolOr(data && data.forceRefresh, false);

    return getOrBuildCachedPayload({
      cacheKey: "listener_leaderboard_v1",
      ttlMs: LEADERBOARD_TTL_MS,
      forceRefresh,
      build: async () => buildListenerLeaderboardPayload(),
    });
  });

exports.analyticsRefreshCaches_v1 = functions
  .region(REGION)
  .https.onCall(async (_data, context) => {
    assertCallableAppCheck(context, "analyticsRefreshCaches_v1");

    await requireAdmin(context);

    const [summary, today, last7days, retention, leaderboard] =
      await Promise.all([
        buildSummaryPayload(),
        buildTodaySummaryPayload(),
        buildLast7DaysTimeseriesPayload(),
        buildRetentionSummaryPayload(),
        buildListenerLeaderboardPayload(),
      ]);

    await Promise.all([
      writeCache("summary_v1", summary),
      writeCache("today_summary_v1", today),
      writeCache("last7days_timeseries_v1", last7days),
      writeCache("retention_summary_v1", retention),
      writeCache("listener_leaderboard_v1", leaderboard),
    ]);

    return {
      ok: true,
      refreshedAtMs: Date.now(),
    };
  });
