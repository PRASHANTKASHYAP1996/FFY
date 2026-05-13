const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  _assertSandboxTopupEnabled,
  _buildRazorpayOrderResponse,
  _hasUsablePayoutAccountSnapshot,
  _planCancelledWithdrawalHoldRepair,
  _sandboxTopupProjectAllowed,
  _sanitizePayoutAccountSnapshot,
  _validateRazorpayPaymentRecord,
} = require("../src/payments");
const { safeLogFields } = require("../src/shared");

function withEnv(patch, fn) {
  const previous = {};
  for (const key of Object.keys(patch)) {
    previous[key] = process.env[key];
    if (patch[key] === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = patch[key];
    }
  }

  try {
    return fn();
  } finally {
    for (const key of Object.keys(patch)) {
      if (previous[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = previous[key];
      }
    }
  }
}

function assertSandboxDenied(fn) {
  assert.throws(
    fn,
    (err) => err && err.code === "permission-denied" &&
      err.message === "Sandbox top-up is disabled."
  );
}

test("sandbox top-up verification is disabled by default", () => {
  withEnv({
    ENABLE_SANDBOX_TOPUP: undefined,
    FUNCTIONS_EMULATOR: undefined,
  }, () => {
    assertSandboxDenied(() => _assertSandboxTopupEnabled({
      projectId: "friendify-ef682",
      enabled: false,
    }));
  });
});

test("safe log fields redact secrets and shorten identifiers", () => {
  const fields = safeLogFields({
    callId: "call_123456789abcdef",
    uid: "user_123456789abcdef",
    traceId: "trace_123456789abcdef",
    gatewayOrderId: "order_123456789abcdef",
    token: "tok_secret_value",
    message: "hello",
    longText: "x".repeat(170),
    retries: 2,
  });

  assert.equal(fields.callId, "call_1...cdef");
  assert.equal(fields.uid, "user_1...cdef");
  assert.equal(fields.traceId, "trace_...cdef");
  assert.equal(fields.gatewayOrderId, "order_...cdef");
  assert.equal(fields.token, "[redacted]");
  assert.equal(fields.message, "hello");
  assert.equal(fields.longText.length, 160);
  assert.equal(fields.retries, 2);
});

test("sandbox top-up can be enabled for dev or test projects", () => {
  withEnv({
    ENABLE_SANDBOX_TOPUP: "true",
    FUNCTIONS_EMULATOR: undefined,
  }, () => {
    assert.doesNotThrow(() => _assertSandboxTopupEnabled({
      projectId: "friendify-dev",
    }));
    assert.equal(_sandboxTopupProjectAllowed("friendify-test"), true);
  });
});

test("sandbox top-up remains blocked for production-like projects even with flag", () => {
  withEnv({
    ENABLE_SANDBOX_TOPUP: "true",
    FUNCTIONS_EMULATOR: undefined,
  }, () => {
    assertSandboxDenied(() => _assertSandboxTopupEnabled({
      projectId: "friendify-ef682",
    }));
  });
});

test("sandbox top-up can be enabled in the local functions emulator", () => {
  withEnv({
    ENABLE_SANDBOX_TOPUP: "true",
    FUNCTIONS_EMULATOR: "true",
  }, () => {
    assert.doesNotThrow(() => _assertSandboxTopupEnabled({
      projectId: "friendify-ef682",
    }));
  });
});

test("sandbox verification path does not invoke Razorpay gateway verification", () => {
  const paymentsSource = fs.readFileSync(
    path.join(__dirname, "..", "src", "payments.js"),
    "utf8",
  );
  const start = paymentsSource.indexOf("exports.verifyTopupSandbox_v1");
  const end = paymentsSource.indexOf("exports.failTopupOrder_v1");
  assert.ok(start >= 0);
  assert.ok(end > start);

  const sandboxVerifierSource = paymentsSource.slice(start, end);
  assert.equal(
    sandboxVerifierSource.includes("assertRazorpayPaymentVerifiedByGateway"),
    false,
  );
  assert.equal(sandboxVerifierSource.includes("razorpayOrderId"), false);
});

test("payout account snapshot sanitizer stores only safe whitelisted fields", () => {
  const sanitized = _sanitizePayoutAccountSnapshot({
    payoutMethod: "BANK",
    accountHolderName: "  Friend User  ",
    accountNumber: "123456789012",
    ifsc: " hdfc0001234 ",
    bankName: "Friendify Bank",
    accountType: "savings",
    secretToken: "do-not-store",
  });

  assert.deepEqual(sanitized, {
    payoutMethod: "bank",
    accountHolderName: "Friend User",
    bankName: "Friendify Bank",
    accountType: "savings",
    ifsc: "HDFC0001234",
    maskedAccountNumber: "****9012",
  });
  assert.equal(Object.hasOwn(sanitized, "accountNumber"), false);
  assert.equal(Object.hasOwn(sanitized, "secretToken"), false);
});

test("payout account snapshot sanitizer rejects non-object payloads", () => {
  assert.throws(
    () => _sanitizePayoutAccountSnapshot("upi:user@example"),
    (error) => error && error.code === "invalid-argument"
  );
});

test("withdrawal payout snapshot validator requires a usable destination", () => {
  assert.equal(_hasUsablePayoutAccountSnapshot({}), false);
  assert.equal(_hasUsablePayoutAccountSnapshot({
    payoutMethod: "upi",
    upiId: "friend@upi",
  }), true);
  assert.equal(_hasUsablePayoutAccountSnapshot({
    payoutMethod: "bank",
    accountHolderName: "Friend User",
    ifsc: "HDFC0001234",
    maskedAccountNumber: "****9012",
  }), true);
  assert.equal(_hasUsablePayoutAccountSnapshot({
    payoutMethod: "manual_support",
  }), false);
});

test("cancelled withdrawal with stale hold plans a hold repair", () => {
  const repairPlan = _planCancelledWithdrawalHoldRepair({
    request: {
      status: "cancelled",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
      holdStatus: "held",
      cancelledBy: "userA",
      cancelledAtMs: 1234,
    },
    user: {
      pendingWithdrawalCredits: 120,
    },
    requestId: "withdraw_cancel_1",
  });

  assert.equal(repairPlan.kind, "repair");
  assert.equal(repairPlan.userId, "userA");
  assert.equal(repairPlan.heldCredits, 80);
  assert.equal(repairPlan.newPendingWithdrawalCredits, 40);
  assert.equal(repairPlan.cancelledBy, "userA");
  assert.equal(repairPlan.cancelledAtMs, 1234);
});

test("cancelled withdrawal hold repair stays noop after release", () => {
  const repairPlan = _planCancelledWithdrawalHoldRepair({
    request: {
      status: "cancelled",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
      holdStatus: "released",
    },
    user: {
      pendingWithdrawalCredits: 0,
    },
    requestId: "withdraw_cancel_2",
  });

  assert.deepEqual(repairPlan, {kind: "noop"});
});

test("Razorpay payment validator requires captured matching payment details", () => {
  assert.deepEqual(
    _validateRazorpayPaymentRecord({
      payment: {
        order_id: "order_123",
        amount: 5000,
        currency: "INR",
        status: "captured",
      },
      expectedOrderId: "order_123",
      expectedAmountPaise: 5000,
      expectedCurrency: "INR",
    }),
    {
      orderId: "order_123",
      amount: 5000,
      currency: "INR",
      status: "captured",
    },
  );

  assert.throws(
    () => _validateRazorpayPaymentRecord({
      payment: {
        order_id: "order_123",
        amount: 5000,
        currency: "INR",
        status: "authorized",
      },
      expectedOrderId: "order_123",
      expectedAmountPaise: 5000,
      expectedCurrency: "INR",
    }),
    (error) => error && error.code === "failed-precondition" &&
      /not captured/.test(error.message),
  );

  assert.throws(
    () => _validateRazorpayPaymentRecord({
      payment: {
        order_id: "order_other",
        amount: 5000,
        currency: "INR",
        status: "captured",
      },
      expectedOrderId: "order_123",
      expectedAmountPaise: 5000,
      expectedCurrency: "INR",
    }),
    (error) => error && error.code === "failed-precondition" &&
      /does not belong/.test(error.message),
  );

  assert.throws(
    () => _validateRazorpayPaymentRecord({
      payment: {
        order_id: "order_123",
        amount: 4900,
        currency: "INR",
        status: "captured",
      },
      expectedOrderId: "order_123",
      expectedAmountPaise: 5000,
      expectedCurrency: "INR",
    }),
    (error) => error && error.code === "failed-precondition" &&
      /amount/.test(error.message),
  );
});

test("Razorpay order response includes server key id and gateway order ids", () => {
  assert.deepEqual(
    _buildRazorpayOrderResponse({
      orderId: "payment_doc_123",
      keyId: "rzp_test_public_key",
      gatewayOrderId: "order_abc123",
      amount: 250,
      currency: "INR",
    }),
    {
      ok: true,
      orderId: "payment_doc_123",
      keyId: "rzp_test_public_key",
      razorpayOrderId: "order_abc123",
      gatewayOrderId: "order_abc123",
      amount: 250,
      currency: "INR",
      gateway: "razorpay",
      status: "pending",
      testMode: true,
      launchMode: "test_only",
      paymentModeLabel: "Razorpay test flow",
      payoutModeLabel: "manual_test",
      realMoneyEnabled: false,
      productionReady: false,
    },
  );
});
