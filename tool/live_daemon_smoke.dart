// Live-daemon smoke test: runs against a real Haveno daemon (XMR_LOCAL docker
// network from haveno-ts, user1 daemon at localhost:9999 password "apitest").
//
// Usage: dart run tool/live_daemon_smoke.dart [url] [apiPassword]
//
// Exercises: version/connection, account create-or-open, full initialization,
// balances, payment methods/accounts, offer book, trade statistics.
import 'dart:io';

import 'package:haveno_dart/haveno_dart.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty ? args[0] : 'http://localhost:9999';
  final password = args.length > 1 ? args[1] : 'apitest';
  const accountPassword = 'haveno-dart-e2e';
  final client = HavenoClient(url, password);
  var failed = false;

  void log(String s) => print(s);

  try {
    log('getVersion -> ${await client.getVersion()}');
    log('isConnectedToDaemon -> ${await client.isConnectedToDaemon()}');

    if (!await client.accountExists()) {
      log('accountExists -> false; createAccount("$accountPassword")');
      await client.createAccount(accountPassword);
    } else {
      log('accountExists -> true; openAccount("$accountPassword")');
      try {
        await client.openAccount(accountPassword);
      } catch (e) {
        log('openAccount raised (continuing): $e');
      }
    }

    await client.awaitAppInitialized().timeout(const Duration(minutes: 3));
    log('awaitAppInitialized -> done');
    log('isAppInitialized -> ${await client.isAppInitialized()}');
    log('isAccountOpen -> ${await client.isAccountOpen()}');

    log('getBalances -> ${await client.getBalances()}');
    log('getPaymentMethods -> ${(await client.getPaymentMethods()).length} methods');
    log('getPaymentAccounts -> ${(await client.getPaymentAccounts()).length} accounts');
    log('getOffers(USD) -> ${(await client.getOffers('USD')).length} offers');
    log('getTradeStatistics -> ${(await client.getTradeStatistics()).length} entries');
    log('SMOKE OK');
  } catch (e, st) {
    failed = true;
    log('SMOKE FAILED: $e');
    log('$st');
  } finally {
    await client.close();
  }

  exitCode = failed ? 1 : 0;
}
