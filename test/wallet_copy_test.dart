import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/screens/wallet_details_screen.dart';

void main() {
  test('wallet transaction labels use standardized production wording', () {
    expect(walletTransactionTitle('topup'), 'Top-up');
    expect(walletTransactionTitle('call_charge'), 'Call charge');
    expect(walletTransactionTitle('refund'), 'Refund');
    expect(walletTransactionTitle('call_earning'), 'Earnings credit');
    expect(walletTransactionTitle('withdrawal_request'), 'Withdrawal request');
  });

  test('wallet status labels map to pending completed failed', () {
    expect(walletStatusLabel('pending'), 'Pending');
    expect(walletStatusLabel('created'), 'Pending');
    expect(walletStatusLabel('verified'), 'Completed');
    expect(walletStatusLabel('completed'), 'Completed');
    expect(walletStatusLabel('failed'), 'Failed');
    expect(walletStatusLabel('cancelled'), 'Failed');
  });
}
