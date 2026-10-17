import 'package:haveno_dart/haveno_dart.dart';

/// Connects to a locally running Haveno daemon and prints some basic state.
///
/// Start the daemon with the gRPC API enabled, e.g.:
///   haveno-daemon --apiPassword=apiPassword --appName=haveno-example
Future<void> main() async {
  final client = HavenoClient('http://localhost:8079', 'apiPassword');
  try {
    if (!await client.isConnectedToDaemon()) {
      print('Could not connect to Haveno daemon at ${client.getUrl()}');
      return;
    }

    print('Haveno version: ${await client.getVersion()}');
    print('Account created: ${await client.accountExists()}');
    print('Account open: ${await client.isAccountOpen()}');

    if (await client.isAppInitialized()) {
      final balances = await client.getBalances();
      print('XMR available: ${HavenoUtils.atomicUnitsToXmr(balances.availableBalance)}');

      final offers = await client.getOffers('USD', OfferDirection.BUY);
      print('${offers.length} offers to buy XMR for USD');
    }
  } on HavenoError catch (e) {
    print('Haveno error: $e');
  } finally {
    await client.close();
  }
}
