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
} = require("./shared");

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

const APP_CHECK_CALLABLE_MODE = (() => {
  const configured = strOr(process.env.APP_CHECK_ENFORCE_CALLABLES, "off")
    .trim()
    .toLowerCase();
  if (configured === "off" || configured === "monitor" || configured === "enforce") {
    return configured;
  }
  console.warn(
    `[appcheck] invalid APP_CHECK_ENFORCE_CALLABLES="${configured}", defaulting to "off"`
  );
  return "off";
})();

function appCheckEnforceEnabled() {
  return APP_CHECK_CALLABLE_MODE === "enforce";
}

function appCheckMonitorEnabled() {
  return APP_CHECK_CALLABLE_MODE === "monitor";
}

function assertCallableAppCheck(context, fnName) {
  const appId = strOr(context && context.app && context.app.appId).trim();
  if (appId) return;

  if (appCheckMonitorEnabled()) {
    const uid = strOr(context && context.auth && context.auth.uid).trim();
    console.log(
      `[appcheck-monitor] missing token on ${fnName} uid=${uid || "anonymous"}`
    );
    return;
  }

  if (appCheckEnforceEnabled()) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "App Check token is required."
    );
  }
}

function assertTestOnlyTopup({
  amount,
  currency,
  gateway,
  requestRealMoney = false,
}) {
  if (amount < MIN_TOPUP_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Minimum top-up is ₹${MIN_TOPUP_AMOUNT}`
    );
  }

  if (amount > MAX_TOPUP_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Maximum top-up is ₹${MAX_TOPUP_AMOUNT}`
    );
  }

  if (currency !== "INR") {
    throw new functions.https.HttpsError(
      "invalid-argument",
      "Only INR is supported in the current build"
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
      "Real money mode is disabled in this build. Use test/sandbox mode only."
    );
  }
}

function assertTestOnlyWithdrawal({
  amount,
  payoutMode,
  realMoneyEnabled = false,
}) {
  if (amount < MIN_WITHDRAWAL_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Minimum withdrawal is ₹${MIN_WITHDRAWAL_AMOUNT}`
    );
  }

  if (amount > MAX_WITHDRAWAL_AMOUNT) {
    throw new functions.https.HttpsError(
      "invalid-argument",
      `Maximum withdrawal is ₹${MAX_WITHDRAWAL_AMOUNT}`
    );
  }

  if (realMoneyEnabled) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Real money payouts are disabled in this build."
    );
  }

  const safePayoutMode = strOr(payoutMode, "manual_test").trim().toLowerCase();
  if (safePayoutMode !== "manual_test") {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "Only manual_test payout mode is allowed in this build."
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
  const metadata = data && typeof data.metadata === "object" && data.metadata ? data.metadata : {};
  const requestRealMoney = boolOr(data && data.enableRealMoney, false);

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

  const userId = context.auth.uid;
  const orderId = strOr(data && data.orderId).trim();
  const paymentId = strOr(data && data.paymentId).trim() || `sandbox_pay_${Date.now()}`;
  const approve = boolOr(data && data.approve, true);

  if (!orderId) {
    throw new functions.https.HttpsError("invalid-argument", "orderId required");
  }

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
    console.log("verifyTopupSandbox_v1 duplicate blocked:", orderId);
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

exports.createRazorpayOrder_v1 = functions.region(REGION).https.onCall(async (data, context) => {
  assertCallableAppCheck(context, "createRazorpayOrder_v1");

  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Login required");
  }

  const userId = context.auth.uid;
  const amount = intOr(data && data.amount, 0);
  const currency = safeCurrency(data && data.currency);
  const metadata = data && typeof data.metadata === "object" && data.metadata ? data.metadata : {};

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
    console.log("createRazorpayOrder_v1 Razorpay create error:", e);
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

  return {
    ok: true,
    orderId: orderRef.id,
    razorpayOrderId: gatewayOrderId,
    gatewayOrderId,
    amount,
    currency,
    gateway: "razorpay",
    status: "pending",
    testMode: true,
    ...launchModeMeta({ gateway: "razorpay" }),
  };
});

exports.verifyRazorpayPayment_v1 = functions.region(REGION).https.onCall(async (data, context) => {
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

  if (expectedSignature !== signature) {
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
    console.log("verifyRazorpayPayment_v1 duplicate blocked:", orderId);
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
    throw new functions.https.HttpsError(
      "resource-exhausted",
      "Duplicate withdrawal attempt blocked. Please wait a moment and try again."
    );
  }

  const userRef = db.collection("users").doc(userId);

  const [userSnap, pendingSnap] = await Promise.all([
    userRef.get(),
    db.collection("withdrawal_requests")
      .where("userId", "==", userId)
      .where("status", "==", "pending")
      .limit(1)
      .get(),
  ]);

  if (!userSnap.exists) {
    throw new functions.https.HttpsError("failed-precondition", "User profile missing");
  }

  if (!pendingSnap.empty) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      "You already have a pending withdrawal request."
    );
  }

  const user = userSnap.data() || {};
  const earningsCredits = intOr(user.earningsCredits, 0);
  const credits = intOr(user.credits, 0);
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
      `You can request up to ₹${earningsCredits}`
    );
  }

  if (amount > credits) {
    throw new functions.https.HttpsError(
      "failed-precondition",
      `Your current credits are lower than the requested withdrawal amount. Current credits: ₹${credits}`
    );
  }

  const nowMs = Date.now();
  const requestRef = db.collection("withdrawal_requests").doc();

  await requestRef.set({
    userId,
    userName: displayName,
    amount,
    note,
    status: "pending",
    payoutMode: "manual_test",
    realMoneyEnabled: false,
    earningsSnapshot: earningsCredits,
    creditsSnapshot: credits,
    requestedAt: admin.firestore.FieldValue.serverTimestamp(),
    requestedAtMs: nowMs,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    updatedAtMs: nowMs,
    statusReason: "",
    currency: "INR",
    adminNote: "",
    payoutAccountSnapshot: {},
    idempotencyKey: `withdraw_${userId}_${nowMs}`,
    settledInLedger: false,
    launchMode: "test_only",
    productionReady: false,
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

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(requestRef);
    if (!snap.exists) {
      throw new functions.https.HttpsError("not-found", "Withdrawal request not found");
    }

    const req = snap.data() || {};
    const ownerId = strOr(req.userId);
    const status = strOr(req.status).trim().toLowerCase();
    const settledInLedger = req.settledInLedger === true;

    if (ownerId !== userId) {
      throw new functions.https.HttpsError("permission-denied", "This request is not yours");
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

    tx.update(requestRef, {
      status: "cancelled",
      cancelledBy: userId,
      cancelledAt: admin.firestore.FieldValue.serverTimestamp(),
      cancelledAtMs: Date.now(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAtMs: Date.now(),
      statusReason: "Cancelled by user",
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