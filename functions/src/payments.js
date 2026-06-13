const {
  admin,
  functions,
  REGION,
  MIN_WITHDRAWAL_AMOUNT,
  MAX_WITHDRAWAL_AMOUNT,
  MIN_TOPUP_AMOUNT,
  MAX_TOPUP_AMOUNT,
  intOr,
  strOr,
  boolOr,
  assertCallableAppCheck,
  safeCurrency,
  getRazorpayClient,
  getRazorpayConfig,
  crypto,
  walletTxRef,
  buildTopupTxId,
  paymentOrderRef,
  createWalletTxDoc,
  createPaymentOrderDoc,
  acquireExecutionLock,
  shortLogId,
  logEvent,
  logError,
} = require("./shared");
const {
  computeWithdrawalUsableBalance,
  releaseWithdrawalHoldBalance,
} = require("./withdrawals");

function launchModeMeta({
  gateway = "",
  payoutMode = "",
}) {
  return {
    launchMode: "test_only",
    paymentModeLabel:
      gateway === "razorpay"
        ? "Razorpay test flow"
        : "Sandbox test flow",
    payoutModeLabel:
      payoutMode && payoutMode.trim()
        ? payoutMode.trim()
        : "manual_test",
    realMoneyEnabled: false,
    productionReady: false,
  };
}

function planCancelledWithdrawalHoldRepair({
  request = {},
  user = {},
  requestId = "",
}) {
  const status = strOr(request.status, "pending").toLowerCase();
  const holdStatus = strOr(request.holdStatus).toLowerCase();
  const userId = strOr(request.userId).trim();
  const heldCredits = intOr(request.heldCredits, 0);

  if (status !== "cancelled" || heldCredits <= 0 || holdStatus === "released") {
    return { kind: "noop" };
  }

  if (!userId) {
    return {
      kind: "error",
      code: "failed-precondition",
      message: "Cancelled withdrawal hold cannot be repaired: user missing",
    };
  }

  const pendingWithdrawalCredits = intOr(user.pendingWithdrawalCredits, 0);

  return {
    kind: "repair",
    userId,
    requestId: strOr(requestId).trim(),
    heldCredits,
    newPendingWithdrawalCredits: releaseWithdrawalHoldBalance({
      currentPendingWithdrawalCredits: pendingWithdrawalCredits,
      heldCredits,
    }),
    cancelledBy: strOr(request.cancelledBy),
    cancelledAtMs: intOr(request.cancelledAtMs, 0),
  };
}

exports._planCancelledWithdrawalHoldRepair = planCancelledWithdrawalHoldRepair;

function sanitizeClientMetadata(
  raw,
  { maxKeys = 20, maxKeyLength = 40, maxValueLength = 200 } = {}
) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const out = {};
  let count = 0;
  for (const [key, value] of Object.entries(raw)) {
    if (count >= maxKeys) break;
    const safeKey = strOr(key).trim().slice(0, maxKeyLength);
    if (!safeKey) continue;
    if (typeof value === "string") {
      out[safeKey] = value.slice(0, maxValueLength);
    } else if (typeof value === "number" && Number.isFinite(value)) {
      out[safeKey] = value;
    } else if (typeof value === "boolean") {
      out[safeKey] = value;
    } else {
      continue;
    }
    count += 1;
  }
  return out;
}

exports._sanitizeClientMetadata = sanitizeClientMetadata;

function assertTestOnlyTopup({
  amount,
  currency,
  gateway,
  requestRealMoney = false,
}) {
  if (amount < MIN_TOPUP_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Minimum top-up is Rs ${MIN_TOPUP_AMOUNT}`
    );
  }

  if (amount > MAX_TOPUP_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Maximum top-up is Rs ${MAX_TOPUP_AMOUNT}`
    );
  }

  if (currency !== "INR") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Only INR is supported."
    );
  }

  if (!["sandbox", "razorpay"].includes(gateway)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Unsupported gateway"
    );
  }

  if (requestRealMoney) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Real-money top-ups are not available in this build."
    );
  }
}

function sandboxTopupFlagEnabled() {
  return strOr(process.env.ENABLE_SANDBOX_TOPUP, "")
    .trim()
    .toLowerCase() === "true";
}

function currentProjectId() {
  return strOr(
    process.env.GCLOUD_PROJECT ||
      process.env.GCP_PROJECT ||
      (admin.app().options && admin.app().options.projectId),
    ""
  ).trim();
}

function sandboxTopupProjectAllowed(projectId = currentProjectId()) {
  const safeProjectId = strOr(projectId, "").trim().toLowerCase();
  return process.env.FUNCTIONS_EMULATOR === "true" ||
    safeProjectId.includes("dev") ||
    safeProjectId.includes("test") ||
    safeProjectId.includes("emulator");
}

function assertSandboxTopupEnabled({ projectId, enabled } = {}) {
  const flagEnabled = typeof enabled === "boolean" ? enabled : sandboxTopupFlagEnabled();
  const safeProjectId = strOr(projectId, currentProjectId()).trim();

  if (!flagEnabled || !sandboxTopupProjectAllowed(safeProjectId)) {
    throw new functions.https.HttpsError(
      "permission-denied",
      "Sandbox top-up is disabled."
    );
  }
}

exports._sandboxTopupFlagEnabled = sandboxTopupFlagEnabled;
exports._sandboxTopupProjectAllowed = sandboxTopupProjectAllowed;
exports._assertSandboxTopupEnabled = assertSandboxTopupEnabled;

function payoutSnapshotString(raw, key, maxLength) {
  if (!raw || !(key in raw) || raw[key] === null || raw[key] === undefined) {
    return "";
  }
  const value = raw[key];
  if (typeof value !== "string" && typeof value !== "number") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Payout account details contain an invalid field."
    );
  }
  return String(value).trim().slice(0, maxLength);
}

function sanitizePayoutAccountSnapshot(raw) {
  if (raw === null || raw === undefined) return {};
  if (typeof raw !== "object" || Array.isArray(raw)) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Payout account details must be an object."
    );
  }

  const out = {};
  const payoutMethod = payoutSnapshotString(raw, "payoutMethod", 32).toLowerCase();
  if (["upi", "bank", "manual_support"].includes(payoutMethod)) {
    out.payoutMethod = payoutMethod;
  }

  const accountHolderName = payoutSnapshotString(raw, "accountHolderName", 80);
  if (accountHolderName) out.accountHolderName = accountHolderName;

  const upiId = payoutSnapshotString(raw, "upiId", 80);
  if (upiId) out.upiId = upiId;

  const bankName = payoutSnapshotString(raw, "bankName", 80);
  if (bankName) out.bankName = bankName;

  const accountType = payoutSnapshotString(raw, "accountType", 32);
  if (accountType) out.accountType = accountType;

  const ifsc = payoutSnapshotString(raw, "ifsc", 20)
    .replace(/\s+/g, "")
    .toUpperCase();
  if (ifsc) out.ifsc = ifsc;

  const maskedAccountNumber = payoutSnapshotString(raw, "maskedAccountNumber", 40);
  const rawAccountNumber = payoutSnapshotString(raw, "accountNumber", 40)
    .replace(/\D/g, "");
  if (maskedAccountNumber) {
    out.maskedAccountNumber = maskedAccountNumber;
  } else if (rawAccountNumber) {
    out.maskedAccountNumber = `****${rawAccountNumber.slice(-4)}`;
  }

  return out;
}

exports._sanitizePayoutAccountSnapshot = sanitizePayoutAccountSnapshot;

function hasUsablePayoutAccountSnapshot(snapshot = {}) {
  const payoutMethod = strOr(snapshot.payoutMethod).toLowerCase();
  if (payoutMethod === "upi") {
    return /^[^\s@]+@[^\s@]+$/.test(strOr(snapshot.upiId));
  }
  if (payoutMethod === "bank") {
    return Boolean(
      strOr(snapshot.accountHolderName) &&
      strOr(snapshot.ifsc) &&
      strOr(snapshot.maskedAccountNumber)
    );
  }
  return false;
}

exports._hasUsablePayoutAccountSnapshot = hasUsablePayoutAccountSnapshot;

function validateRazorpayPaymentRecord({
  payment = {},
  expectedOrderId = "",
  expectedAmountPaise = 0,
  expectedCurrency = "INR",
}) {
  const paymentOrderId = strOr(payment.order_id).trim();
  const paymentStatus = strOr(payment.status).trim().toLowerCase();
  const paymentAmount = intOr(payment.amount, 0);
  const paymentCurrency = strOr(payment.currency, "INR").trim().toUpperCase();
  const safeExpectedOrderId = strOr(expectedOrderId).trim();
  const safeExpectedCurrency = safeCurrency(expectedCurrency);
  const safeExpectedAmountPaise = Math.max(0, intOr(expectedAmountPaise, 0));

  if (!paymentOrderId || paymentOrderId !== safeExpectedOrderId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay payment does not belong to this order."
    );
  }

  if (paymentAmount !== safeExpectedAmountPaise) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay payment amount does not match the order."
    );
  }

  if (paymentCurrency !== safeExpectedCurrency) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay payment currency does not match the order."
    );
  }

  if (paymentStatus !== "captured" && payment.captured !== true) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay payment is not captured."
    );
  }

  return {
    orderId: paymentOrderId,
    amount: paymentAmount,
    currency: paymentCurrency,
    status: paymentStatus || (payment.captured === true ? "captured" : ""),
  };
}

async function assertRazorpayPaymentVerifiedByGateway({
  paymentId,
  razorpayOrderId,
  amount,
  currency,
}) {
  const { keyId } = getRazorpayConfig();
  const razorpay = getRazorpayClient();
  let payment;
  try {
    payment = await razorpay.payments.fetch(paymentId);
  } catch (e) {
    console.log("verifyRazorpayPayment_v1 payment fetch error:", e);
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Unable to verify Razorpay payment status."
    );
  }

  return validateRazorpayPaymentRecord({
    payment,
    expectedOrderId: razorpayOrderId,
    expectedAmountPaise: amount * 100,
    expectedCurrency: currency,
  });
}

exports._validateRazorpayPaymentRecord = validateRazorpayPaymentRecord;

function buildRazorpayOrderResponse({
  orderId,
  keyId,
  gatewayOrderId,
  amount,
  currency,
}) {
  return {
    ok: true,
    orderId,
    keyId,
    razorpayOrderId: gatewayOrderId,
    gatewayOrderId,
    amount,
    currency,
    gateway: "razorpay",
    status: "pending",
    testMode: true,
    ...launchModeMeta({ gateway: "razorpay" }),
  };
}

exports._buildRazorpayOrderResponse = buildRazorpayOrderResponse;

function assertTestOnlyWithdrawal({
  amount,
  payoutMode,
  realMoneyEnabled = false,
}) {
  if (amount < MIN_WITHDRAWAL_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Minimum withdrawal is Rs ${MIN_WITHDRAWAL_AMOUNT}`
    );
  }

  if (amount > MAX_WITHDRAWAL_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Maximum withdrawal is Rs ${MAX_WITHDRAWAL_AMOUNT}`
    );
  }

  if (realMoneyEnabled) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Real-money payouts are not available in this build."
    );
  }

  const safePayoutMode = strOr(payoutMode, "manual_test").trim().toLowerCase();
  if (safePayoutMode !== "manual_test") {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Withdrawal payouts are not available in this build."
    );
  }
}

exports.createTopupOrder_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "createTopupOrder_v1");

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const amount = intOr(data && data.amount, 0);
  const currency = safeCurrency(data && data.currency);
  const gateway = strOr(data && data.gateway, "sandbox").trim().toLowerCase();
  const metadata = sanitizeClientMetadata(data && data.metadata);
  const requestRealMoney = boolOr(data && data.enableRealMoney, false);

  logEvent("payment.order.create.request", {
    userId: shortLogId(userId),
    gateway,
    amount,
    currency,
  });

  assertTestOnlyTopup({
    amount,
    currency,
    gateway,
    requestRealMoney,
  });

  const db = admin.firestore();
  const userRef = db.collection("users").doc(userId);
  const userSnap = await userRef.get();

  if (!userSnap.exists) {
    throw new functions.https.HttpsError("failed-precondition", "User profile missing");
  }

  const orderRef = db.collection("payment_orders").doc();
  const nowMs = Date.now();
  const idempotencyKey = `payment_order_${userId}_${nowMs}`;
  const gatewayOrderId = gateway === "sandbox" ? `sandbox_order_${orderRef.id}` : "";

  await orderRef.set(
    createPaymentOrderDoc({
      userId,
      amount,
      currency,
      gateway,
      gatewayOrderId,
      status: gateway === "sandbox" ? "pending" : "created",
      idempotencyKey,
      metadata: {
        ...metadata,
        testMode: true,
        realMoneyEnabled: false,
        launchMode: "test_only",
        productionReady: false,
      },
    }),
    { merge: true }
  );

  logEvent("payment.order.create.result", {
    userId: shortLogId(userId),
    orderId: orderRef.id,
    gateway,
    amount,
    currency,
    status: gateway === "sandbox" ? "pending" : "created",
  });

  return {
    ok: true,
    orderId: orderRef.id,
    gatewayOrderId,
    amount,
    currency,
    gateway,
    status: gateway === "sandbox" ? "pending" : "created",
    testMode: true,
    ...launchModeMeta({ gateway }),
  };
});

exports.verifyTopupSandbox_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "verifyTopupSandbox_v1"); 
  
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  assertSandboxTopupEnabled();

  const userId = context.auth.uid;
  const orderId = strOr(data && data.orderId).trim();
  const paymentId = strOr(data && data.paymentId).trim() || `sandbox_pay_${Date.now()}`;
  const approve = boolOr(data && data.approve, true);

  if (!orderId) {
    throw new functions.https.HttpsError("invalid-argument", "orderId required");
  }

  logEvent("payment.sandbox.verify.request", {
    userId: shortLogId(userId),
    orderId,
    approve,
  });

  const db = admin.firestore();

  const topupLockAcquired = await acquireExecutionLock({
    db,
    lockId: `topup_verify_${orderId}`,
    lockType: "topup_verification",
    resourceId: orderId,
    owner: userId,
    ttlMs: 30000,
  });

  if (!topupLockAcquired) {
    logEvent("payment.sandbox.verify.duplicate_blocked", {
      userId: shortLogId(userId),
      orderId,
    });
    return {
      ok: true,
      orderId,
      paymentId,
      status: "duplicate_blocked",
      testMode: true,
      ...launchModeMeta({ gateway: "sandbox" }),
    };
  }

  const orderRef = paymentOrderRef(db, orderId);
  const userRef = db.collection("users").doc(userId);
  const topupTxRef = walletTxRef(db, buildTopupTxId(orderId));

  await db.runTransaction(async (tx) => {
    const [orderSnap, userSnap, existingTopupTxSnap] = await Promise.all([
      tx.get(orderRef),
      tx.get(userRef),
      tx.get(topupTxRef),
    ]);

    if (!orderSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Payment order not found");
    }

    if (!userSnap.exists) {
      throw new functions.https.HttpsError("failed-precondition", "User profile missing");
    }

    const order = orderSnap.data() || {};
    const orderUserId = strOr(order.userId);
    const orderGateway = strOr(order.gateway, "sandbox").trim().toLowerCase();
    const orderStatus = strOr(order.status).trim().toLowerCase();
    const amount = intOr(order.amount, 0);
    const currency = safeCurrency(order.currency);
    const orderMetadata = order.metadata && typeof order.metadata === "object" ? order.metadata : {};

    if (orderUserId !== userId) {
      throw new functions.https.HttpsError("permission-denied", "This payment order is not yours");
    }

    if (orderGateway !== "sandbox") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Only sandbox verification is supported in this build"
      );
    }

    if (amount < MIN_TOPUP_AMOUNT || amount > MAX_TOPUP_AMOUNT) {
      throw new functions.https.HttpsError("failed-precondition", "Payment order amount is invalid");
    }

    if (orderStatus === "verified" || existingTopupTxSnap.exists) {
      return;
    }

    if (orderStatus === "failed") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Failed payment orders cannot be verified"
      );
    }

    if (!approve) {
      tx.update(orderRef, {
        status: "failed",
        failureReason: "sandbox_declined",
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      return;
    }

    const user = userSnap.data() || {};
    const oldCredits = intOr(user.credits, 0);
    const newCredits = oldCredits + amount;

    tx.update(userRef, {
      credits: newCredits,
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.update(orderRef, {
      paymentId,
      status: "verified",
      verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
      failureReason: "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      metadata: {
        ...orderMetadata,
        verifiedInSandbox: true,
        launchMode: "test_only",
        productionReady: false,
        realMoneyEnabled: false,
      },
    });

    tx.set(
      topupTxRef,
      createWalletTxDoc({
        userId,
        type: "topup",
        amount,
        balanceAfter: newCredits,
        status: "completed",
        method: "sandbox",
        notes: "Sandbox wallet top-up",
        source: "gateway",
        currency,
        direction: "credit",
        paymentOrderId: orderId,
        paymentId,
        gateway: "sandbox",
        idempotencyKey: `topup_${orderId}_${paymentId}`,
        metadata: {
          testMode: true,
          realMoneyEnabled: false,
          launchMode: "test_only",
          productionReady: false,
        },
      })
    );
  });

  logEvent("payment.sandbox.verify.result", {
    userId: shortLogId(userId),
    orderId,
    status: approve ? "verified" : "failed",
  });

  return {
    ok: true,
    orderId,
    paymentId,
    status: approve ? "verified" : "failed",
    testMode: true,
    ...launchModeMeta({ gateway: "sandbox" }),
  };
});

exports.failTopupOrder_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "failTopupOrder_v1");
  
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const orderId = strOr(data && data.orderId).trim();
  const failureReason = strOr(data && data.failureReason, "user_cancelled").trim();

  if (!orderId) {
    throw new functions.https.HttpsError("invalid-argument", "orderId required");
  }

  const db = admin.firestore();
  const orderRef = paymentOrderRef(db, orderId);

  // Share the verification lock so a cancel can't race a concurrent verify.
  const failLockAcquired = await acquireExecutionLock({
    db,
    lockId: `topup_verify_${orderId}`,
    lockType: "topup_verification",
    resourceId: orderId,
    owner: userId,
    ttlMs: 15000,
  });

  if (!failLockAcquired) {
    return {
      ok: true,
      orderId,
      status: "verify_in_progress",
      ...launchModeMeta({ gateway: "sandbox" }),
    };
  }

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(orderRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Payment order not found");
    }

    const order = snap.data() || {};
    const orderUserId = strOr(order.userId);
    const status = strOr(order.status).trim().toLowerCase();

    if (orderUserId !== userId) {
      throw new functions.https.HttpsError("permission-denied", "This payment order is not yours");
    }

    if (status === "verified") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Verified payment orders cannot be marked failed"
      );
    }

    if (status === "failed") {
      return;
    }

    tx.update(orderRef, {
      status: "failed",
      failureReason,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      metadata: {
        ...(order.metadata && typeof order.metadata === "object" ? order.metadata : {}),
        launchMode: "test_only",
        productionReady: false,
        realMoneyEnabled: false,
      },
    });
  });

  return {
    ok: true,
    orderId,
    status: "failed",
    failureReason,
    ...launchModeMeta({ gateway: "sandbox" }),
  };
});

exports.createRazorpayOrder_v1 = functions
  .region(REGION)
  .runWith({ secrets: ["RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"] })
  .https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "createRazorpayOrder_v1");

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const amount = intOr(data && data.amount, 0);
  const currency = safeCurrency(data && data.currency);
  const metadata = sanitizeClientMetadata(data && data.metadata);

  logEvent("payment.razorpay.order.request", {
    userId: shortLogId(userId),
    amount,
    currency,
  });

  assertTestOnlyTopup({
    amount,
    currency,
    gateway: "razorpay",
    requestRealMoney: boolOr(data && data.enableRealMoney, false),
  });

  const db = admin.firestore();
  const userRef = db.collection("users").doc(userId);
  const userSnap = await userRef.get();

  if (!userSnap.exists) {
    throw new functions.https.HttpsError("failed-precondition", "User profile missing");
  }

  const { keyId } = getRazorpayConfig();
  const razorpay = getRazorpayClient();

  let razorpayOrder;
  try {
    razorpayOrder = await razorpay.orders.create({
      amount: amount * 100,
      currency,
      receipt: `friendify_${Date.now()}`,
      notes: {
        userId,
        source: "friendify_wallet_topup",
        launchMode: "test_only",
      },
    });
  } catch (e) {
    logError("payment.razorpay.order.gateway_error", e, {
      userId: shortLogId(userId),
      amount,
      currency,
    });
    throw new functions.https.HttpsError(
      "internal",
      strOr(e && e.message, "Unable to create Razorpay order.")
    );
  }

  const gatewayOrderId = strOr(razorpayOrder && razorpayOrder.id).trim();
  if (!gatewayOrderId) {
    throw new functions.https.HttpsError(
      "internal",
      "Razorpay order id missing from gateway response"
    );
  }

  const orderRef = db.collection("payment_orders").doc();
  const nowMs = Date.now();
  const idempotencyKey = `razorpay_order_${userId}_${nowMs}`;

  await orderRef.set(
    createPaymentOrderDoc({
      userId,
      amount,
      currency,
      gateway: "razorpay",
      gatewayOrderId,
      status: "pending",
      idempotencyKey,
      metadata: {
        ...metadata,
        testMode: true,
        realMoneyEnabled: false,
        razorpayOrderCreated: true,
        launchMode: "test_only",
        productionReady: false,
      },
    }),
    { merge: true }
  );

  logEvent("payment.razorpay.order.result", {
    userId: shortLogId(userId),
    orderId: orderRef.id,
    gatewayOrderId,
    amount,
    currency,
  });

  return buildRazorpayOrderResponse({
    orderId: orderRef.id,
    keyId,
    gatewayOrderId,
    amount,
    currency,
  });
  });

exports.verifyRazorpayPayment_v1 = functions
  .region(REGION)
  .runWith({ secrets: ["RAZORPAY_KEY_ID", "RAZORPAY_KEY_SECRET"] })
  .https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "verifyRazorpayPayment_v1");

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const orderId = strOr(data && data.orderId).trim();
  const razorpayOrderId = strOr(data && data.razorpayOrderId).trim();
  const paymentId = strOr(data && data.paymentId).trim();
  const signature = strOr(data && data.signature).trim();

  if (!orderId) {
    throw new functions.https.HttpsError("invalid-argument", "orderId required");
  }

  if (!razorpayOrderId || !paymentId || !signature) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "razorpayOrderId, paymentId, and signature are required"
    );
  }

  logEvent("payment.razorpay.verify.request", {
    userId: shortLogId(userId),
    orderId,
    gatewayOrderId: razorpayOrderId,
    hasPaymentId: Boolean(paymentId),
  });

  const { keySecret } = getRazorpayConfig();
  if (!keySecret) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay secret is not configured on the server."
    );
  }

  const expectedSignature = crypto
    .createHmac("sha256", keySecret)
    .update(`${razorpayOrderId}|${paymentId}`)
    .digest("hex");

  const expectedSignatureBuf = Buffer.from(expectedSignature, "utf8");
  const providedSignatureBuf = Buffer.from(strOr(signature), "utf8");
  const signatureValid =
    expectedSignatureBuf.length === providedSignatureBuf.length &&
    crypto.timingSafeEqual(expectedSignatureBuf, providedSignatureBuf);

  if (!signatureValid) {
    logEvent("payment.razorpay.verify.failure", {
      userId: shortLogId(userId),
      orderId,
      gatewayOrderId: razorpayOrderId,
      reason: "invalid_signature",
    });
    throw new functions.https.HttpsError("permission-denied", "Invalid payment signature");
  }

  const db = admin.firestore();

  const topupLockAcquired = await acquireExecutionLock({
    db,
    lockId: `razorpay_verify_${orderId}`,
    lockType: "topup_verification",
    resourceId: orderId,
    owner: userId,
    ttlMs: 30000,
  });

  if (!topupLockAcquired) {
    logEvent("payment.razorpay.verify.duplicate_blocked", {
      userId: shortLogId(userId),
      orderId,
    });
    return {
      ok: true,
      orderId,
      paymentId,
      status: "duplicate_blocked",
      testMode: true,
      ...launchModeMeta({ gateway: "razorpay" }),
    };
  }

  const orderRef = paymentOrderRef(db, orderId);
  const userRef = db.collection("users").doc(userId);
  const topupTxRef = walletTxRef(db, buildTopupTxId(orderId));

  const [orderSnapForGateway, existingTopupTxForGateway] = await Promise.all([
    orderRef.get(),
    topupTxRef.get(),
  ]);
  if (!orderSnapForGateway.exists) {
    throw new functions.https.HttpsError("not-found", "Payment order not found");
  }
  const orderForGateway = orderSnapForGateway.data() || {};
  const gatewayOrderUserId = strOr(orderForGateway.userId);
  const gatewayOrderGateway = strOr(orderForGateway.gateway).trim().toLowerCase();
  const gatewayOrderStatus = strOr(orderForGateway.status).trim().toLowerCase();
  const gatewayOrderAmount = intOr(orderForGateway.amount, 0);
  const gatewayOrderCurrency = safeCurrency(orderForGateway.currency);
  const storedGatewayOrderIdForGateway = strOr(orderForGateway.orderId).trim();

  if (gatewayOrderUserId !== userId) {
    throw new functions.https.HttpsError("permission-denied", "This payment order is not yours");
  }
  if (gatewayOrderGateway !== "razorpay") {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "This payment order is not a Razorpay order"
    );
  }
  if (storedGatewayOrderIdForGateway !== razorpayOrderId) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Razorpay order mismatch"
    );
  }
  if (gatewayOrderStatus !== "verified" && !existingTopupTxForGateway.exists) {
    await assertRazorpayPaymentVerifiedByGateway({
      paymentId,
      razorpayOrderId,
      amount: gatewayOrderAmount,
      currency: gatewayOrderCurrency,
    });
  }

  await db.runTransaction(async (tx) => {
    const [orderSnap, userSnap, existingTopupTxSnap] = await Promise.all([
      tx.get(orderRef),
      tx.get(userRef),
      tx.get(topupTxRef),
    ]);

    if (!orderSnap.exists) {
      throw new functions.https.HttpsError("not-found", "Payment order not found");
    }

    if (!userSnap.exists) {
      throw new functions.https.HttpsError("failed-precondition", "User profile missing");
    }

    const order = orderSnap.data() || {};
    const orderUserId = strOr(order.userId);
    const orderGateway = strOr(order.gateway).trim().toLowerCase();
    const orderStatus = strOr(order.status).trim().toLowerCase();
    const amount = intOr(order.amount, 0);
    const currency = safeCurrency(order.currency);
    const orderMetadata = order.metadata && typeof order.metadata === "object" ? order.metadata : {};
    const storedGatewayOrderId = strOr(order.orderId).trim();

    if (orderUserId !== userId) {
      throw new functions.https.HttpsError("permission-denied", "This payment order is not yours");
    }

    if (orderGateway !== "razorpay") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This payment order is not a Razorpay order"
      );
    }

    if (!storedGatewayOrderId) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Stored gateway order id missing on server order"
      );
    }

    if (storedGatewayOrderId !== razorpayOrderId) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Razorpay order mismatch"
      );
    }

    if (amount < MIN_TOPUP_AMOUNT || amount > MAX_TOPUP_AMOUNT) {
      throw new functions.https.HttpsError("failed-precondition", "Payment order amount is invalid");
    }

    if (orderStatus === "verified" || existingTopupTxSnap.exists) {
      return;
    }

    if (orderStatus === "failed") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Failed payment orders cannot be verified"
      );
    }

    const user = userSnap.data() || {};
    const oldCredits = intOr(user.credits, 0);
    const newCredits = oldCredits + amount;

    tx.update(userRef, {
      credits: newCredits,
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.update(orderRef, {
      paymentId,
      status: "verified",
      verifiedAt: admin.firestore.FieldValue.serverTimestamp(),
      failureReason: "",
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      metadata: {
        ...orderMetadata,
        verifiedVia: "razorpay_signature",
        verifiedInTestFlow: true,
        launchMode: "test_only",
        productionReady: false,
        realMoneyEnabled: false,
      },
    });

    tx.set(
      topupTxRef,
      createWalletTxDoc({
        userId,
        type: "topup",
        amount,
        balanceAfter: newCredits,
        status: "completed",
        method: "razorpay",
        notes: "Razorpay wallet top-up",
        source: "gateway",
        currency,
        direction: "credit",
        paymentOrderId: orderId,
        paymentId,
        gateway: "razorpay",
        idempotencyKey: `topup_${orderId}_${paymentId}`,
        metadata: {
          razorpayOrderId,
          testMode: true,
          realMoneyEnabled: false,
          launchMode: "test_only",
          productionReady: false,
        },
      })
    );
  });

  logEvent("payment.razorpay.verify.result", {
    userId: shortLogId(userId),
    orderId,
    gatewayOrderId: razorpayOrderId,
    status: "verified",
  });

  return {
    ok: true,
    orderId,
    paymentId,
    status: "verified",
    testMode: true,
    ...launchModeMeta({ gateway: "razorpay" }),
  };
  });

exports.requestWithdrawal_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "requestWithdrawal_v1");
 
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const amount = intOr(data && data.amount, 0);
  const note = strOr(data && data.note, "").trim().slice(0, 200);
  const payoutMode = strOr(data && data.payoutMode, "manual_test").trim();
  const realMoneyEnabled = boolOr(data && data.realMoneyEnabled, false);
  const payoutAccountSnapshot = sanitizePayoutAccountSnapshot(
    data && data.payoutAccountSnapshot
  );

  if (!hasUsablePayoutAccountSnapshot(payoutAccountSnapshot)) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Add a payout method before requesting withdrawal."
    );
  }

  logEvent("withdrawal.create.request", {
    userId: shortLogId(userId),
    amount,
    payoutMode,
    realMoneyEnabled,
    hasPayoutSnapshot: Object.keys(payoutAccountSnapshot).length > 0,
  });

  assertTestOnlyWithdrawal({
    amount,
    payoutMode,
    realMoneyEnabled,
  });

  const db = admin.firestore();

  const withdrawalLockAcquired = await acquireExecutionLock({
    db,
    lockId: `withdraw_request_${userId}`,
    lockType: "withdrawal_processing",
    resourceId: userId,
    owner: userId,
    ttlMs: 15000,
  });

  if (!withdrawalLockAcquired) {
    logEvent("withdrawal.create.duplicate_blocked", {
      userId: shortLogId(userId),
    });
    throw new functions.https.HttpsError(
      "resource-exhausted",
      "Duplicate withdrawal attempt blocked. Please wait a moment and try again."
    );
  }

  const userRef = db.collection("users").doc(userId);
  const pendingSnap = await db.collection("withdrawal_requests")
    .where("userId", "==", userId)
    .where("status", "==", "pending")
    .limit(1)
    .get();

  if (!pendingSnap.empty) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "You already have a pending withdrawal request."
    );
  }

  const nowMs = Date.now();
  const requestRef = db.collection("withdrawal_requests").doc();

  await db.runTransaction(async (tx) => {
    const userSnap = await tx.get(userRef);
    if (!userSnap.exists) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "User profile missing"
      );
    }

    const user = userSnap.data() || {};
    const earningsCredits = intOr(user.earningsCredits, 0);
    const credits = intOr(user.credits, 0);
    const reservedCredits = intOr(user.reservedCredits, 0);
    const pendingWithdrawalCredits = intOr(
      user.pendingWithdrawalCredits,
      0
    );
    const usableCredits = computeWithdrawalUsableBalance({
      credits,
      reservedCredits,
      pendingWithdrawalCredits,
    });
    const displayName = strOr(user.displayName, "Friendify User");

    if (earningsCredits <= 0) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "You do not have earnings available for withdrawal yet."
      );
    }

    if (amount > earningsCredits) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `You can request up to INR ${earningsCredits}`
      );
    }

    if (amount > usableCredits) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        `Your usable balance is lower than the requested withdrawal amount. Current usable balance: INR ${usableCredits}`
      );
    }

    tx.update(userRef, {
      pendingWithdrawalCredits: pendingWithdrawalCredits + amount,
      lastSeen: admin.firestore.FieldValue.serverTimestamp(),
    });

    tx.set(requestRef, {
      userId,
      userName: displayName,
      amount,
      note,
      status: "pending",
      payoutMode: "manual_test",
      realMoneyEnabled: false,
      earningsSnapshot: earningsCredits,
      creditsSnapshot: credits,
      reservedCreditsSnapshot: reservedCredits,
      usableCreditsSnapshot: usableCredits,
      heldCredits: amount,
      holdStatus: "held",
      requestedAt: admin.firestore.FieldValue.serverTimestamp(),
      requestedAtMs: nowMs,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: nowMs,
      statusReason: "",
      currency: "INR",
      adminNote: "",
      payoutAccountSnapshot,
      idempotencyKey: `withdraw_${userId}_${nowMs}`,
      settledInLedger: false,
      launchMode: "test_only",
      productionReady: false,
    });
  });

  logEvent("withdrawal.create.result", {
    userId: shortLogId(userId),
    requestId: requestRef.id,
    amount,
    status: "pending",
  });

  return {
    ok: true,
    requestId: requestRef.id,
    amount,
    status: "pending",
    ...launchModeMeta({ payoutMode: "manual_test" }),
  };
});

exports.cancelMyWithdrawal_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "cancelMyWithdrawal_v1");

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const requestId = strOr(data && data.requestId, "").trim();

  if (!requestId) {
    throw new functions.https.HttpsError("invalid-argument", "requestId required");
  }

  const db = admin.firestore();
  const requestRef = db.collection("withdrawal_requests").doc(requestId);
  const userRef = db.collection("users").doc(userId);

  await db.runTransaction(async (tx) => {
    const [snap, userSnap] = await Promise.all([tx.get(requestRef), tx.get(userRef)]);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Withdrawal request not found");
    }

    const req = snap.data() || {};
    const ownerId = strOr(req.userId);
    const status = strOr(req.status).trim().toLowerCase();
    const settledInLedger = req.settledInLedger === true;
    const heldCredits = intOr(req.heldCredits, 0);

    if (ownerId !== userId) {
      throw new functions.https.HttpsError("permission-denied", "This request is not yours");
    }

    if (status === "cancelled") {
      const repairPlan = planCancelledWithdrawalHoldRepair({
        request: req,
        user: userSnap.exists ? userSnap.data() || {} : {},
        requestId,
      });

      if (repairPlan.kind === "error") {
        throw new functions.https.HttpsError(
          repairPlan.code,
          repairPlan.message
        );
      }

      if (repairPlan.kind === "repair") {
        const now = Date.now();
        if (!userSnap.exists) {
          throw new functions.https.HttpsError("not-found", "User not found");
        }

        tx.update(userRef, {
          pendingWithdrawalCredits: repairPlan.newPendingWithdrawalCredits,
          lastSeen: admin.firestore.FieldValue.serverTimestamp(),
        });

        tx.update(requestRef, {
          holdStatus: "released",
          holdReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
          holdReleasedAtMs: now,
          holdReleaseReason: "cancelled_hold_repair",
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          updatedAtMs: now,
        });
      }

      return;
    }

    if (status !== "pending") {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "Only pending requests can be cancelled"
      );
    }

    if (settledInLedger) {
      throw new functions.https.HttpsError(
        "failed-precondition",
        "This request has already been settled and cannot be cancelled"
      );
    }

    if (userSnap.exists && heldCredits > 0) {
      const user = userSnap.data() || {};
      const pendingWithdrawalCredits = intOr(user.pendingWithdrawalCredits, 0);
      tx.update(userRef, {
        pendingWithdrawalCredits: releaseWithdrawalHoldBalance({
          currentPendingWithdrawalCredits: pendingWithdrawalCredits,
          heldCredits,
        }),
        lastSeen: admin.firestore.FieldValue.serverTimestamp(),
      });
    }

    tx.update(requestRef, {
      status: "cancelled",
      cancelledBy: userId,
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      cancelledAtMs: Date.now(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: Date.now(),
      statusReason: "Cancelled by user",
      holdStatus: "released",
      holdReleasedAt: admin.firestore.FieldValue.serverTimestamp(),
      holdReleaseReason: "cancelled_by_user",
      launchMode: "test_only",
      productionReady: false,
      realMoneyEnabled: false,
    });
  });

  return {
    ok: true,
    requestId,
    status: "cancelled",
    ...launchModeMeta({ payoutMode: "manual_test" }),
  };
});
