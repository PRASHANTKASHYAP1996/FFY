const test = require("node:test");
const assert = require("node:assert/strict");

const {
  computeWithdrawalUsableBalance,
  releaseWithdrawalHoldBalance,
} = require("../src/withdrawals");
const {
  _planWithdrawalApproval,
  _planApprovedWithdrawalLedgerRepair,
  _buildApprovedWithdrawalLedgerRepairMutation,
  _planRejectedWithdrawalHoldRepair,
  _planWithdrawalPayoutProofUpdate,
  _buildWithdrawalPayoutProofMutation,
} = require("../src/admin");

test("request withdrawal then spend credits before approval causes approval failure", () => {
  const approvalPlan = _planWithdrawalApproval({
    request: {
      status: "pending",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
    },
    user: {
      credits: 40,
      earningsCredits: 120,
      reservedCredits: 0,
      pendingWithdrawalCredits: 80,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_1",
  });

  assert.equal(approvalPlan.kind, "error");
  assert.equal(approvalPlan.code, "failed-precondition");
  assert.match(approvalPlan.message, /Insufficient usable balance/);
});

test("approval succeeds when usable funds are still available", () => {
  const approvalPlan = _planWithdrawalApproval({
    request: {
      status: "pending",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
      currency: "INR",
      payoutMode: "manual_test",
      realMoneyEnabled: false,
    },
    user: {
      credits: 100,
      earningsCredits: 120,
      reservedCredits: 10,
      pendingWithdrawalCredits: 80,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    adminNote: "approved",
    paymentReference: " UTR-12345 ",
    requestId: "withdraw_2",
  });

  assert.equal(approvalPlan.kind, "apply");
  assert.equal(approvalPlan.newCredits, 20);
  assert.equal(approvalPlan.newEarningsCredits, 40);
  assert.equal(approvalPlan.newPendingWithdrawalCredits, 0);
  assert.equal(approvalPlan.currency, "INR");
  assert.equal(approvalPlan.paymentReference, "UTR-12345");
});

test("rejection or cancellation releases the held withdrawal amount", () => {
  assert.equal(
    releaseWithdrawalHoldBalance({
      currentPendingWithdrawalCredits: 80,
      heldCredits: 80,
    }),
    0
  );

  assert.equal(
    releaseWithdrawalHoldBalance({
      currentPendingWithdrawalCredits: 120,
      heldCredits: 80,
    }),
    40
  );
});

test("duplicate approval remains idempotent", () => {
  const approvalPlan = _planWithdrawalApproval({
    request: {
      status: "approved",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
    },
    user: {
      credits: 100,
      earningsCredits: 100,
      reservedCredits: 0,
      pendingWithdrawalCredits: 0,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_3",
  });

  assert.deepEqual(approvalPlan, {kind: "noop"});
});

test("approved withdrawal missing ledger plans a repair", () => {
  const repairPlan = _planApprovedWithdrawalLedgerRepair({
    request: {
      status: "approved",
      userId: "userA",
      amount: 80,
      currency: "INR",
      payoutMode: "manual_test",
      realMoneyEnabled: false,
      approvedBy: "admin_old",
      approvedAtMs: 1234,
    },
    user: {
      credits: 20,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    paymentReference: "repair-ref",
    requestId: "withdraw_4",
    existingLedgerExists: false,
  });

  assert.equal(repairPlan.kind, "repair");
  assert.equal(repairPlan.userId, "userA");
  assert.equal(repairPlan.amount, 80);
  assert.equal(repairPlan.balanceAfter, 20);
  assert.equal(repairPlan.originalApprovedBy, undefined);
  assert.equal(repairPlan.approvedBy, "admin_old");
  assert.equal(repairPlan.approvedAtMs, 1234);
  assert.equal(repairPlan.paymentReference, "repair-ref");
});

test("approved withdrawal repair stays noop when ledger already exists", () => {
  const repairPlan = _planApprovedWithdrawalLedgerRepair({
    request: {
      status: "approved",
      userId: "userA",
      amount: 80,
      settledInLedger: true,
      settlementLedgerTxId: "withdrawal_withdraw_5_debit",
    },
    user: {
      credits: 20,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_5",
    existingLedgerExists: true,
  });

  assert.deepEqual(repairPlan, {kind: "noop"});
});

test("approved withdrawal existing ledger can repair missing proof fields", () => {
  const repairPlan = _planApprovedWithdrawalLedgerRepair({
    request: {
      status: "approved",
      userId: "userA",
      amount: 80,
      settledInLedger: false,
    },
    user: {
      credits: 20,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_5b",
    existingLedgerExists: true,
  });

  assert.equal(repairPlan.kind, "mark_settled");
  assert.equal(repairPlan.userId, "userA");
  assert.equal(repairPlan.amount, 80);
});

test("approved withdrawal ledger repair mutation writes ledger request and audit docs", () => {
  const mutation = _buildApprovedWithdrawalLedgerRepairMutation({
    repairPlan: {
      kind: "repair",
      userId: "userA",
      requestId: "withdraw_6",
      amount: 80,
      balanceAfter: 20,
      currency: "INR",
      payoutMode: "manual_test",
      realMoneyEnabled: true,
      adminUid: "admin_1",
      adminSource: "custom_claim",
      paymentReference: "repair-ref",
      approvedBy: "admin_old",
      approvedAtMs: 1234,
    },
    requestId: "withdraw_6",
    ledgerTxId: "withdrawal_withdraw_6_debit",
    currentStatus: "approved",
    now: 9999,
    auditActionId: "audit_ledger_repair",
    serverTimestamp: () => "SERVER_TIMESTAMP",
  });

  assert.deepEqual(mutation.requestPatch, {
    settledInLedger: true,
    settlementLedgerTxId: "withdrawal_withdraw_6_debit",
    paymentReference: "repair-ref",
    ledgerRepairedAt: "SERVER_TIMESTAMP",
    ledgerRepairedAtMs: 9999,
    ledgerRepairedBy: "admin_1",
    updatedAt: "SERVER_TIMESTAMP",
    updatedAtMs: 9999,
  });

  assert.deepEqual(mutation.auditDoc, {
    actionId: "audit_ledger_repair",
    actionType: "withdrawal_request_ledger_repaired",
    actionCategory: "finance",
    requestId: "withdraw_6",
    targetUserId: "userA",
    adminUid: "admin_1",
    adminSource: "custom_claim",
    beforeStatus: "approved",
    afterStatus: "approved",
    amount: 80,
    currency: "INR",
    paymentReference: "repair-ref",
    ledgerTxId: "withdrawal_withdraw_6_debit",
    originalApprovedBy: "admin_old",
    originalApprovedAtMs: 1234,
    createdAt: "SERVER_TIMESTAMP",
    createdAtMs: 9999,
  });

  assert.equal(mutation.ledgerDoc.userId, "userA");
  assert.equal(mutation.ledgerDoc.type, "withdrawal_debit");
  assert.equal(mutation.ledgerDoc.amount, -80);
  assert.equal(mutation.ledgerDoc.balanceAfter, 20);
  assert.equal(mutation.ledgerDoc.status, "completed");
  assert.equal(mutation.ledgerDoc.method, "manual_test");
  assert.equal(mutation.ledgerDoc.source, "admin_withdrawal_repair");
  assert.equal(mutation.ledgerDoc.currency, "INR");
  assert.equal(mutation.ledgerDoc.direction, "debit");
  assert.equal(mutation.ledgerDoc.withdrawalRequestId, "withdraw_6");
  assert.equal(mutation.ledgerDoc.idempotencyKey, "withdrawal_debit_withdraw_6");
  assert.equal(mutation.ledgerDoc.createdAt, "SERVER_TIMESTAMP");
  assert.deepEqual(mutation.ledgerDoc.metadata, {
    requestId: "withdraw_6",
    repairedBy: "admin_1",
    adminSource: "custom_claim",
    paymentReference: "repair-ref",
    originalApprovedBy: "admin_old",
    approvedAtMs: 1234,
    payoutMode: "manual_test",
    realMoneyEnabled: true,
  });
});

test("approved withdrawal ledger proof mutation marks request and audit only", () => {
  const mutation = _buildApprovedWithdrawalLedgerRepairMutation({
    repairPlan: {
      kind: "mark_settled",
      userId: "userA",
      requestId: "withdraw_7",
      amount: 80,
      currency: "INR",
      adminUid: "admin_1",
      adminSource: "custom_claim",
      approvedBy: "admin_old",
      approvedAtMs: 1234,
    },
    requestId: "withdraw_7",
    ledgerTxId: "withdrawal_withdraw_7_debit",
    currentStatus: "approved",
    now: 9999,
    auditActionId: "audit_ledger_proof",
    serverTimestamp: () => "SERVER_TIMESTAMP",
  });

  assert.equal(mutation.ledgerDoc, null);
  assert.deepEqual(mutation.requestPatch, {
    settledInLedger: true,
    settlementLedgerTxId: "withdrawal_withdraw_7_debit",
    ledgerProofRepairedAt: "SERVER_TIMESTAMP",
    ledgerProofRepairedAtMs: 9999,
    ledgerProofRepairedBy: "admin_1",
    updatedAt: "SERVER_TIMESTAMP",
    updatedAtMs: 9999,
  });
  assert.deepEqual(mutation.auditDoc, {
    actionId: "audit_ledger_proof",
    actionType: "withdrawal_request_ledger_proof_repaired",
    actionCategory: "finance",
    requestId: "withdraw_7",
    targetUserId: "userA",
    adminUid: "admin_1",
    adminSource: "custom_claim",
    beforeStatus: "approved",
    afterStatus: "approved",
    amount: 80,
    currency: "INR",
    ledgerTxId: "withdrawal_withdraw_7_debit",
    originalApprovedBy: "admin_old",
    originalApprovedAtMs: 1234,
    createdAt: "SERVER_TIMESTAMP",
    createdAtMs: 9999,
  });
});

test("rejected withdrawal with stale hold plans a hold repair", () => {
  const repairPlan = _planRejectedWithdrawalHoldRepair({
    request: {
      status: "rejected",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
      holdStatus: "held",
      rejectedBy: "admin_old",
      rejectedAtMs: 4567,
    },
    user: {
      pendingWithdrawalCredits: 120,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_6",
  });

  assert.equal(repairPlan.kind, "repair");
  assert.equal(repairPlan.userId, "userA");
  assert.equal(repairPlan.heldCredits, 80);
  assert.equal(repairPlan.newPendingWithdrawalCredits, 40);
  assert.equal(repairPlan.rejectedBy, "admin_old");
  assert.equal(repairPlan.rejectedAtMs, 4567);
});

test("rejected withdrawal hold repair stays noop after release", () => {
  const repairPlan = _planRejectedWithdrawalHoldRepair({
    request: {
      status: "rejected",
      userId: "userA",
      amount: 80,
      heldCredits: 80,
      holdStatus: "released",
    },
    user: {
      pendingWithdrawalCredits: 0,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    requestId: "withdraw_7",
  });

  assert.deepEqual(repairPlan, {kind: "noop"});
});

test("approved withdrawal payout proof update captures audit fields", () => {
  const proofPlan = _planWithdrawalPayoutProofUpdate({
    request: {
      status: "approved",
      userId: "userA",
      amount: 80,
      currency: "INR",
      paymentReference: "",
      settlementLedgerTxId: "withdrawal_debit_1",
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    paymentReference: " UTR-98765 ",
    adminNote: "backfilled after bank transfer",
    requestId: "withdraw_8",
  });

  assert.equal(proofPlan.kind, "apply");
  assert.equal(proofPlan.userId, "userA");
  assert.equal(proofPlan.paymentReference, "UTR-98765");
  assert.equal(proofPlan.beforePaymentReference, "");
  assert.equal(proofPlan.settlementLedgerTxId, "withdrawal_debit_1");
  assert.equal(proofPlan.adminUid, "admin_1");
});

test("payout proof update rejects non-approved withdrawals", () => {
  const proofPlan = _planWithdrawalPayoutProofUpdate({
    request: {
      status: "pending",
      userId: "userA",
      amount: 80,
    },
    adminMeta: {
      uid: "admin_1",
      source: "test",
    },
    paymentReference: "UTR-98765",
    requestId: "withdraw_9",
  });

  assert.equal(proofPlan.kind, "error");
  assert.equal(proofPlan.code, "failed-precondition");
});

test("payout proof mutation writes request ledger and audit docs", () => {
  const mutation = _buildWithdrawalPayoutProofMutation({
    proofPlan: {
      requestId: "withdraw_10",
      userId: "userA",
      amount: 80,
      currency: "INR",
      beforePaymentReference: "",
      paymentReference: "UTR-98765",
      adminNote: "bank transfer confirmed",
      adminUid: "admin_1",
      adminSource: "test",
      settlementLedgerTxId: "withdrawal_withdraw_10_debit",
    },
    now: 9999,
    auditActionId: "audit_1",
    serverTimestamp: () => "SERVER_TIMESTAMP",
  });

  assert.deepEqual(mutation.requestPatch, {
    paymentReference: "UTR-98765",
    payoutProofUpdatedAt: "SERVER_TIMESTAMP",
    payoutProofUpdatedAtMs: 9999,
    payoutProofUpdatedBy: "admin_1",
    payoutProofAdminNote: "bank transfer confirmed",
    updatedAt: "SERVER_TIMESTAMP",
    updatedAtMs: 9999,
  });
  assert.deepEqual(mutation.ledgerPatch, {
    metadata: {
      paymentReference: "UTR-98765",
      payoutProofUpdatedBy: "admin_1",
      payoutProofUpdatedAtMs: 9999,
    },
    updatedAt: "SERVER_TIMESTAMP",
    updatedAtMs: 9999,
  });
  assert.deepEqual(mutation.ledgerOptions, { merge: true });
  assert.deepEqual(mutation.auditDoc, {
    actionId: "audit_1",
    actionType: "withdrawal_payout_proof_updated",
    actionCategory: "finance",
    requestId: "withdraw_10",
    targetUserId: "userA",
    adminUid: "admin_1",
    adminSource: "test",
    beforeStatus: "approved",
    afterStatus: "approved",
    amount: 80,
    currency: "INR",
    beforePaymentReference: "",
    paymentReference: "UTR-98765",
    note: "bank transfer confirmed",
    notePresent: true,
    ledgerTxId: "withdrawal_withdraw_10_debit",
    createdAt: "SERVER_TIMESTAMP",
    createdAtMs: 9999,
  });
});

test("payout proof mutation skips ledger patch without settlement id", () => {
  const mutation = _buildWithdrawalPayoutProofMutation({
    proofPlan: {
      requestId: "withdraw_11",
      userId: "userA",
      paymentReference: "UTR-111",
      adminUid: "admin_1",
    },
    now: 1000,
    auditActionId: "audit_2",
    serverTimestamp: () => "SERVER_TIMESTAMP",
  });

  assert.equal(mutation.ledgerPatch, null);
  assert.equal(mutation.auditDoc.ledgerTxId, "");
  assert.equal(mutation.auditDoc.notePresent, false);
});

test("usable withdrawal balance excludes reserved credits and other holds", () => {
  const usableBalance = computeWithdrawalUsableBalance({
    credits: 150,
    reservedCredits: 30,
    pendingWithdrawalCredits: 70,
    currentRequestHeldCredits: 40,
  });

  assert.equal(usableBalance, 90);
});
