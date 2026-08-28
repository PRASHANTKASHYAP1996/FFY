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
const {
  safeLogFields,
  assertRazorpayProductionCredentials,
  evaluateRazorpayCredentials,
  classifyRazorpayKeyId,
  isNonProductionPaymentEnvironment,
  resolveRuntimeProjectId,
} = require("../src/shared");

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


// ---------- production Razorpay credential guard ----------

const PROD = "friendify-ef682";
const LIVE = "rzp_live_EXAMPLEONLY";
const TEST = "rzp_test_EXAMPLEONLY";

function assertPaymentConfigRejected(fn) {
  assert.throws(fn, (err) => {
    assert.equal(err.code, "failed-precondition");
    assert.equal(err.message, "payment_configuration_invalid");
    return true;
  });
}

test("production project rejects a missing Razorpay key id", () => {
  assertPaymentConfigRejected(() =>
    assertRazorpayProductionCredentials({
      keyId: "",
      keySecret: "secret-placeholder",
      projectId: PROD,
      emulator: false,
    })
  );
});

test("production project rejects a test-mode Razorpay key", () => {
  assertPaymentConfigRejected(() =>
    assertRazorpayProductionCredentials({
      keyId: TEST,
      keySecret: "secret-placeholder",
      projectId: PROD,
      emulator: false,
    })
  );
});

test("production project rejects an unrecognised Razorpay key prefix", () => {
  assertPaymentConfigRejected(() =>
    assertRazorpayProductionCredentials({
      keyId: "sk_live_wrongvendor",
      keySecret: "secret-placeholder",
      projectId: PROD,
      emulator: false,
    })
  );
});

test("production project rejects a live key with a blank secret", () => {
  for (const secret of ["", "   "]) {
    assertPaymentConfigRejected(() =>
      assertRazorpayProductionCredentials({
        keyId: LIVE,
        keySecret: secret,
        projectId: PROD,
        emulator: false,
      })
    );
  }
});

test("production project accepts a live key with a non-blank secret", () => {
  assert.doesNotThrow(() =>
    assertRazorpayProductionCredentials({
      keyId: LIVE,
      keySecret: "secret-placeholder",
      projectId: PROD,
      emulator: false,
    })
  );
});

test("functions emulator still accepts a test key", () => {
  assert.doesNotThrow(() =>
    assertRazorpayProductionCredentials({
      keyId: TEST,
      keySecret: "secret-placeholder",
      projectId: PROD,
      emulator: true,
    })
  );
});

test("clearly named dev or test projects still accept a test key", () => {
  for (const projectId of ["friendify-dev", "friendify-test", "my-emulator-proj"]) {
    assert.doesNotThrow(() =>
      assertRazorpayProductionCredentials({
        keyId: TEST,
        keySecret: "secret-placeholder",
        projectId,
        emulator: false,
      })
    );
  }
});

test("unknown non-emulator projects are treated as production and reject test keys", () => {
  for (const projectId of ["", "some-unlabelled-project"]) {
    assertPaymentConfigRejected(() =>
      assertRazorpayProductionCredentials({
        keyId: TEST,
        keySecret: "secret-placeholder",
        projectId,
        emulator: false,
      })
    );
  }
});

test("credential guard never exposes key or secret values", () => {
  const secret = "super-secret-value-should-never-appear";
  const keyId = "rzp_test_SHOULDNEVERAPPEAR";
  let captured = null;
  try {
    assertRazorpayProductionCredentials({
      keyId,
      keySecret: secret,
      projectId: PROD,
      emulator: false,
    });
  } catch (err) {
    captured = err;
  }
  assert.ok(captured, "guard must reject");
  const serialised = JSON.stringify({
    message: captured.message,
    details: captured.details,
    code: captured.code,
  });
  assert.ok(!serialised.includes(secret), "secret must not leak");
  assert.ok(!serialised.includes(keyId), "key id must not leak");
  assert.ok(!serialised.includes("SHOULDNEVERAPPEAR"), "key fragment must not leak");
  assert.equal(captured.details.reason, "payment_configuration_invalid");
});

test("key classification is coarse and value-free", () => {
  assert.equal(classifyRazorpayKeyId(LIVE), "live");
  assert.equal(classifyRazorpayKeyId(TEST), "test");
  assert.equal(classifyRazorpayKeyId(""), "missing");
  assert.equal(classifyRazorpayKeyId("nonsense"), "invalid");
  const evaluated = evaluateRazorpayCredentials({
    keyId: TEST,
    keySecret: "secret-placeholder",
    projectId: PROD,
    emulator: false,
  });
  assert.equal(evaluated.ok, false);
  assert.equal(evaluated.keyClass, "test");
  assert.ok(!JSON.stringify(evaluated).includes("EXAMPLEONLY"));
});

test("environment classification uses trusted runtime signals only", () => {
  withEnv(
    {
      GCLOUD_PROJECT: undefined,
      GCP_PROJECT: undefined,
      FUNCTIONS_EMULATOR: undefined,
      FIREBASE_CONFIG: JSON.stringify({ projectId: "friendify-dev" }),
    },
    () => {
      assert.equal(resolveRuntimeProjectId(), "friendify-dev");
      assert.equal(isNonProductionPaymentEnvironment(), true);
    }
  );

  withEnv(
    {
      GCLOUD_PROJECT: undefined,
      GCP_PROJECT: undefined,
      FUNCTIONS_EMULATOR: undefined,
      FIREBASE_CONFIG: "{not-json",
    },
    () => {
      assert.equal(resolveRuntimeProjectId(), "");
      assert.equal(isNonProductionPaymentEnvironment(), false);
    }
  );

  withEnv(
    {
      GCLOUD_PROJECT: PROD,
      GCP_PROJECT: undefined,
      FUNCTIONS_EMULATOR: undefined,
      FIREBASE_CONFIG: undefined,
    },
    () => {
      assert.equal(resolveRuntimeProjectId(), PROD);
      assert.equal(isNonProductionPaymentEnvironment(), false);
    }
  );
});

test("both Razorpay callables invoke the guard before gateway or mutation", () => {
  const source = fs.readFileSync(
    path.join(__dirname, "..", "src", "payments.js"),
    "utf8"
  );
  for (const fnName of ["createRazorpayOrder_v1", "verifyRazorpayPayment_v1"]) {
    const start = source.indexOf(`assertCallableAppCheck(context, "${fnName}")`);
    assert.ok(start > -1, `${fnName} must exist`);
    const guardAt = source.indexOf("assertRazorpayProductionCredentials()", start);
    assert.ok(guardAt > -1, `${fnName} must call the credential guard`);

    for (const sideEffect of [
      "getRazorpayClient()",
      "razorpay.orders.create",
      "razorpay.payments.fetch",
      "createHmac",
      "runTransaction",
    ]) {
      const at = source.indexOf(sideEffect, start);
      if (at > -1) {
        assert.ok(
          guardAt < at,
          `${fnName}: guard must run before ${sideEffect}`
        );
      }
    }
  }
});

test("non-payment callables do not invoke the payment credential guard", () => {
  const social = fs.readFileSync(
    path.join(__dirname, "..", "src", "social.js"),
    "utf8"
  );
  assert.ok(!social.includes("assertRazorpayProductionCredentials"));
});
