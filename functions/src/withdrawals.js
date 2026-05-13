const {
  intOr,
} = require("./shared");

function computeWithdrawalUsableBalance({
  credits = 0,
  reservedCredits = 0,
  pendingWithdrawalCredits = 0,
  currentRequestHeldCredits = 0,
}) {
  const safeCredits = Math.max(0, intOr(credits, 0));
  const safeReservedCredits = Math.max(0, intOr(reservedCredits, 0));
  const safePendingWithdrawalCredits = Math.max(
    0,
    intOr(pendingWithdrawalCredits, 0)
  );
  const safeCurrentRequestHeldCredits = Math.max(
    0,
    Math.min(
      safePendingWithdrawalCredits,
      intOr(currentRequestHeldCredits, 0)
    )
  );
  const otherPendingWithdrawalCredits = Math.max(
    0,
    safePendingWithdrawalCredits - safeCurrentRequestHeldCredits
  );

  return Math.max(
    0,
    safeCredits - safeReservedCredits - otherPendingWithdrawalCredits
  );
}

function releaseWithdrawalHoldBalance({
  currentPendingWithdrawalCredits = 0,
  heldCredits = 0,
}) {
  const safePendingWithdrawalCredits = Math.max(
    0,
    intOr(currentPendingWithdrawalCredits, 0)
  );
  const safeHeldCredits = Math.max(0, intOr(heldCredits, 0));
  return Math.max(0, safePendingWithdrawalCredits - safeHeldCredits);
}

module.exports = {
  computeWithdrawalUsableBalance,
  releaseWithdrawalHoldBalance,
};
