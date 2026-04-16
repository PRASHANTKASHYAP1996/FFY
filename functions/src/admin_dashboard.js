const { admin, functions, REGION, strOr, intOr } = require("./shared");

async function requireAdmin(context) {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const uid = strOr(context.auth.uid).trim();
  if (!uid) {
    throw new functions.https.HttpsError("unauthenticated", "Invalid auth context");
  }

  const token = context.auth.token || {};
  const customClaimAdmin =
    token.admin === true ||
    token.isAdmin === true ||
    strOr(token.role).toLowerCase() === "admin";

  if (customClaimAdmin) {
    return {
      uid,
      source: "custom_claim",
    };
  }

  const adminSnap = await admin.firestore().collection("users").doc(uid).get();
  if (!adminSnap.exists) {
    throw new functions.https.HttpsError("permission-denied", "Admin access required");
  }

  const adminData = adminSnap.data() || {};
  const firestoreAdmin =
    adminData.isAdmin === true ||
    adminData.admin === true ||
    strOr(adminData.role).toLowerCase() === "admin" ||
    strOr(adminData.userRole).toLowerCase() === "admin";

  if (!firestoreAdmin) {
    throw new functions.https.HttpsError("permission-denied", "Admin access required");
  }

  return {
    uid,
    source: "firestore",
  };
}

const ADMIN_DASHBOARD_CACHE_ROOT = "admin_dashboard_cache";
const DASHBOARD_TTL_MS = 2 * 60 * 1000;

function numOr(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function round2(value) {
  return Number(numOr(value, 0).toFixed(2));
}

function tsToMillis(value) {
  if (!value) return 0;
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (value && typeof value.toMillis === "function") {
    try {
      return value.toMillis();
    } catch (_) {
      return 0;
    }
  }
  if (value instanceof Date) return value.getTime();
  return 0;
}

function sortByCreatedDesc(items) {
  items.sort((a, b) => {
    const aTime = numOr(a.createdAtMs || a.updatedAtMs || 0, 0);
    const bTime = numOr(b.createdAtMs || b.updatedAtMs || 0, 0);
    return bTime - aTime;
  });
  return items;
}

function dashboardCacheRef(docId) {
  return admin
    .firestore()
    .collection("system")
    .doc(ADMIN_DASHBOARD_CACHE_ROOT)
    .collection("docs")
    .doc(docId);
}

async function readFreshCacheOrNull(docId, maxAgeMs) {
  const snap = await dashboardCacheRef(docId).get();
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
  await dashboardCacheRef(docId).set(
    {
      refreshedAt: admin.firestore.FieldValue.serverTimestamp(),
      refreshedAtMs: Date.now(),
      payload,
    },
    { merge: true }
  );
}

async function buildDashboardPayload(adminMeta) {
  const db = admin.firestore();

  const [
    usersSnap,
    callsSnap,
    withdrawalsSnap,
    reviewsSnap,
  ] = await Promise.all([
    db.collection("users").get(),
    db.collection("calls").get(),
    db.collection("withdrawal_requests").get(),
    db.collection("reviews").get(),
  ]);

  const usersDocs = usersSnap.docs;
  const callsDocs = callsSnap.docs;
  const withdrawalsDocs = withdrawalsSnap.docs;
  const reviewsDocs = reviewsSnap.docs;

  let totalUsers = 0;
  let totalListeners = 0;
  let availableListeners = 0;
  let blockedUsers = 0;

  let totalCredits = 0;
  let totalEarningsCredits = 0;
  let totalReservedCredits = 0;

  const recentUsers = [];

  for (const doc of usersDocs) {
    const data = doc.data() || {};
    totalUsers += 1;

    const isListener = data.isListener === true;
    const isAvailable = data.isAvailable === true;
    const isBlocked = data.adminBlocked === true;
    const hasActiveCall = strOr(data.activeCallId).length > 0;

    if (isListener) totalListeners += 1;
    if (isListener && isAvailable && !hasActiveCall) availableListeners += 1;
    if (isBlocked) blockedUsers += 1;

    totalCredits += intOr(data.credits, 0);
    totalEarningsCredits += intOr(data.earningsCredits, 0);
    totalReservedCredits += intOr(data.reservedCredits, 0);

    recentUsers.push({
      id: doc.id,
      displayName: strOr(data.displayName || data.name || ""),
      email: strOr(data.email || ""),
      photoURL: strOr(data.photoURL || ""),
      isListener,
      isAvailable,
      adminBlocked: isBlocked,
      credits: intOr(data.credits, 0),
      earningsCredits: intOr(data.earningsCredits, 0),
      followersCount: intOr(data.followersCount, 0),
      ratingAvg: round2(numOr(data.ratingAvg, 0)),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.lastSeen),
        intOr(data.lastSeenMs, 0)
      ),
    });
  }

  let totalCalls = 0;
  let ringingCalls = 0;
  let acceptedCalls = 0;
  let endedCalls = 0;
  let rejectedCalls = 0;
  let missedCalls = 0;
  let paidCalls = 0;
  let freeCalls = 0;

  let totalBilledCredits = 0;
  let totalListenerPayoutCredits = 0;
  let totalPlatformRevenueCredits = 0;
  let totalCallDurationSeconds = 0;

  const recentCalls = [];

  for (const doc of callsDocs) {
    const data = doc.data() || {};
    totalCalls += 1;

    const status = strOr(data.status, "").toLowerCase();
    if (status === "ringing") ringingCalls += 1;
    if (status === "accepted") acceptedCalls += 1;
    if (status === "ended") endedCalls += 1;
    if (status === "rejected") rejectedCalls += 1;

    const endedReason = strOr(data.endedReason || data.endReason || "").toLowerCase();
    if (
      endedReason === "missed" ||
      endedReason === "timeout" ||
      endedReason === "no_answer" ||
      endedReason === "not_answered"
    ) {
      missedCalls += 1;
    }

    const durationSeconds = intOr(
      data.billableDurationSeconds ||
        data.durationSeconds ||
        data.totalDurationSeconds ||
        data.endedSeconds ||
        data.seconds ||
        0,
      0
    );

    const billedCredits = intOr(
      data.finalChargeCredits ||
        data.totalChargeCredits ||
        data.chargeCredits ||
        data.speakerCharge ||
        0,
      0
    );

    const listenerPayoutCredits = intOr(
      data.listenerPayoutCredits ||
        data.payoutCredits ||
        data.listenerPayout ||
        0,
      0
    );

    const platformRevenueCredits = intOr(
      data.platformRevenueCredits ||
        data.platformFeeCredits ||
        data.platformProfit ||
        0,
      0
    );

    totalCallDurationSeconds += durationSeconds;
    totalBilledCredits += billedCredits;
    totalListenerPayoutCredits += listenerPayoutCredits;
    totalPlatformRevenueCredits += platformRevenueCredits;

    if (billedCredits > 0) {
      paidCalls += 1;
    } else {
      freeCalls += 1;
    }

    recentCalls.push({
      id: doc.id,
      callerId: strOr(data.callerId || ""),
      calleeId: strOr(data.calleeId || ""),
      callerName: strOr(data.callerName || ""),
      calleeName: strOr(data.calleeName || ""),
      status,
      endedReason,
      durationSeconds,
      billedCredits,
      listenerPayoutCredits,
      platformRevenueCredits,
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.acceptedAt),
        tsToMillis(data.endedAt),
        intOr(data.acceptedAtMs, 0),
        intOr(data.endedAtMs, 0)
      ),
    });
  }

  let totalWithdrawalRequests = 0;
  let pendingWithdrawalRequests = 0;
  let approvedWithdrawalRequests = 0;
  let rejectedWithdrawalRequests = 0;

  let pendingWithdrawalAmount = 0;
  let approvedWithdrawalAmount = 0;
  let rejectedWithdrawalAmount = 0;

  const recentWithdrawals = [];

  for (const doc of withdrawalsDocs) {
    const data = doc.data() || {};
    totalWithdrawalRequests += 1;

    const status = strOr(data.status, "pending").toLowerCase();
    const amount = intOr(data.amount, 0);

    if (status === "pending") {
      pendingWithdrawalRequests += 1;
      pendingWithdrawalAmount += amount;
    } else if (status === "approved") {
      approvedWithdrawalRequests += 1;
      approvedWithdrawalAmount += amount;
    } else if (status === "rejected") {
      rejectedWithdrawalRequests += 1;
      rejectedWithdrawalAmount += amount;
    }

    recentWithdrawals.push({
      id: doc.id,
      userId: strOr(data.userId || ""),
      status,
      amount,
      currency: strOr(data.currency || "INR"),
      payoutMode: strOr(data.payoutMode || ""),
      adminNote: strOr(data.adminNote || ""),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0),
        tsToMillis(data.approvedAt),
        tsToMillis(data.rejectedAt),
        intOr(data.approvedAtMs, 0),
        intOr(data.rejectedAtMs, 0)
      ),
    });
  }

  let totalReviews = 0;
  let reviewRatingSum = 0;
  let validReviewRatingCount = 0;

  const recentReviews = [];

  for (const doc of reviewsDocs) {
    const data = doc.data() || {};
    totalReviews += 1;

    const rating = numOr(data.rating || data.stars, 0);
    if (rating > 0) {
      reviewRatingSum += rating;
      validReviewRatingCount += 1;
    }

    recentReviews.push({
      id: doc.id,
      reviewerId: strOr(data.reviewerId || ""),
      revieweeId: strOr(data.revieweeId || data.userId || data.reviewedUserId || ""),
      reviewerName: strOr(data.reviewerName || ""),
      revieweeName: strOr(data.revieweeName || ""),
      rating: round2(rating),
      comment: strOr(data.comment || ""),
      createdAtMs: Math.max(
        tsToMillis(data.createdAt),
        intOr(data.createdAtMs, 0)
      ),
      updatedAtMs: Math.max(
        tsToMillis(data.updatedAt),
        intOr(data.updatedAtMs, 0)
      ),
    });
  }

  const averageReviewRating =
    validReviewRatingCount > 0
      ? round2(reviewRatingSum / validReviewRatingCount)
      : 0;

  sortByCreatedDesc(recentUsers);
  sortByCreatedDesc(recentCalls);
  sortByCreatedDesc(recentWithdrawals);
  sortByCreatedDesc(recentReviews);

  return {
    ok: true,
    adminUid: adminMeta.uid,
    adminSource: adminMeta.source,
    generatedAtMs: Date.now(),

    summary: {
      users: {
        total: totalUsers,
        listeners: totalListeners,
        availableListeners,
        blockedUsers,
      },
      wallet: {
        totalCredits,
        totalEarningsCredits,
        totalReservedCredits,
      },
      withdrawals: {
        totalRequests: totalWithdrawalRequests,
        pendingRequests: pendingWithdrawalRequests,
        approvedRequests: approvedWithdrawalRequests,
        rejectedRequests: rejectedWithdrawalRequests,
        pendingAmount: pendingWithdrawalAmount,
        approvedAmount: approvedWithdrawalAmount,
        rejectedAmount: rejectedWithdrawalAmount,
      },
      calls: {
        total: totalCalls,
        ringing: ringingCalls,
        accepted: acceptedCalls,
        ended: endedCalls,
        rejected: rejectedCalls,
        missed: missedCalls,
        paid: paidCalls,
        free: freeCalls,
        totalDurationSeconds: totalCallDurationSeconds,
        totalBilledCredits,
        totalListenerPayoutCredits,
        totalPlatformRevenueCredits,
      },
      reviews: {
        total: totalReviews,
        averageRating: averageReviewRating,
      },
    },

    lists: {
      recentUsers: recentUsers.slice(0, 20),
      recentCalls: recentCalls.slice(0, 20),
      recentWithdrawals: recentWithdrawals.slice(0, 20),
      recentReviews: recentReviews.slice(0, 20),
    },
  };
}

exports.adminGetDashboard_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  const adminMeta = await requireAdmin(context);
  const forceRefresh = data && data.forceRefresh === true;

  if (!forceRefresh) {
    const cached = await readFreshCacheOrNull("dashboard_v1", DASHBOARD_TTL_MS);
    if (cached) {
      return cached;
    }
  }

  const payload = await buildDashboardPayload(adminMeta);
  await writeCache("dashboard_v1", payload);
  return payload;
});

exports.adminRefreshDashboardCache_v1 = functions
  .region(REGION)
  .https.onCall(async (_data, context) => {
    const adminMeta = await requireAdmin(context);
    const payload = await buildDashboardPayload(adminMeta);
    await writeCache("dashboard_v1", payload);

    return {
      ok: true,
      refreshedAtMs: Date.now(),
    };
  });