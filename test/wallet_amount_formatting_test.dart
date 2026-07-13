import 'package:flutter_test/flutter_test.dart';

import 'package:friendify/shared/wallet_amount_formatter.dart';

void main() {
  test('wallet amount formatter renders INR amounts', () {
    expect(formatWalletAmount(0), '₹0');
    expect(formatWalletAmount(125), '₹125');
  });

  test('wallet signed amount formatter preserves sign and absolute value', () {
    expect(formatSignedWalletAmount(125), '+₹125');
    expect(formatSignedWalletAmount(-125), '-₹125');
  });

  test('wallet currency amount formatter keeps INR on rupee symbol', () {
    expect(formatWalletCurrencyAmount(250), '₹250');
    expect(formatWalletCurrencyAmount(250, currency: 'INR'), '₹250');
    expect(formatWalletCurrencyAmount(250, currency: 'usd'), 'USD 250');
  });

  test('wallet signed currency amount formatter keeps sign mapping stable', () {
    expect(formatSignedWalletCurrencyAmount(250), '+₹250');
    expect(formatSignedWalletCurrencyAmount(-250), '-₹250');
    expect(
      formatSignedWalletCurrencyAmount(-250, currency: 'usd'),
      '-USD 250',
    );
  });
}
