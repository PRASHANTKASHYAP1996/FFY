String formatWalletAmount(int amount) => '₹$amount';

String formatSignedWalletAmount(int amount) {
  final prefix = amount < 0 ? '-' : '+';
  return '$prefix₹${amount.abs()}';
}

String formatWalletCurrencyAmount(
  int amount, {
  String currency = 'INR',
}) {
  final safeCurrency = currency.trim().toUpperCase();
  if (safeCurrency.isEmpty || safeCurrency == 'INR') {
    return formatWalletAmount(amount);
  }
  return '$safeCurrency $amount';
}

String formatSignedWalletCurrencyAmount(
  int amount, {
  String currency = 'INR',
}) {
  final safeCurrency = currency.trim().toUpperCase();
  if (safeCurrency.isEmpty || safeCurrency == 'INR') {
    return formatSignedWalletAmount(amount);
  }
  final prefix = amount < 0 ? '-' : '+';
  return '$prefix$safeCurrency ${amount.abs()}';
}
