# Live-daemon test — 2026-10-17

**Result: PASS.** The Dart client (`haveno-dart`) was run against a real
`haveno-daemon` (v1.11.0) on a local Haveno XMR_LOCAL network (the docker
network shipped with haveno-ts). This closes the "never ran against a live
daemon" gap for the bounty submission.

## Environment

- Host: Windows, Docker Desktop 4.65 (WSL2 backend, host networking)
- Network: `haveno-ts/docker/docker-compose.yml`, services `node1`
  (monerod), `node2`, `seed1`, `seed2`, `user1` (`haveno-daemon`)
- Daemon under test: `user1` — XMR_LOCAL, `--apiPassword=apitest`,
  `--apiPort=9999`, `--passwordRequired=false`
- Client script: `tool/live_daemon_smoke.dart` (in this repo)

The daemon API binds loopback inside its container, so the Dart test ran in a
`dart:stable` container sharing user1's network namespace:

```
docker run --rm --network container:user1 \
  -v "C:/Users/bachu/Downloads/OpenCode/haveno-dart:/src:ro" dart:stable \
  bash -c "cp -r /src /work && cd /work && dart pub get && \
           dart run tool/live_daemon_smoke.dart http://127.0.0.1:9999 apitest"
```

## Raw transcript

```
$ dart pub get
Got dependencies!
--- PUBGET OK ---
getVersion -> 1.11.0
isConnectedToDaemon -> true
accountExists -> true; openAccount("haveno-dart-e2e")
openAccount raised (continuing): HavenoError(2): Incorrect password
awaitAppInitialized -> done
isAppInitialized -> true
isAccountOpen -> true
getBalances ->
getPaymentMethods -> 79 methods
getPaymentAccounts -> 0 accounts
getOffers(USD) -> 0 offers
getTradeStatistics -> 0 entries
SMOKE OK
```

Daemon-side confirmation (docker logs user1):

```
XmrConnectionService.setConnection() called with connection: http://127.0.0.1:28081
[HavenoDaemonMain] INFO haveno.core.app.AppStartupState: Application fully initialized
```

## What this proves

- Real gRPC handshake + auth (`apiPassword` as metadata) against the actual daemon
- Typed reply parsing: version string, booleans, 79 payment methods from the daemon
- Account lifecycle: `accountExists` → `openAccount`, `awaitAppInitialized()`
  over the daemon's notification stream, `isAppInitialized`, `isAccountOpen`
- Error mapping: the daemon's `FAILED_PRECONDITION("Incorrect password")`
  surfaces as `HavenoError(2)` — honest error propagation, not a crash
- Wallet/offer/statistics calls all round-trip cleanly (zero values on a fresh
  local network, as expected)

## Honest caveats

- The XMR_LOCAL `user1` daemon had been bootstrapped once before this run
  (`--passwordRequired=false`), so an account already existed that was not
  created with this script's password — hence the (handled) "Incorrect
  password" line. The create-account path is covered by the in-process gRPC
  integration tests; a fresh-daemon run of `createAccount` is the natural next
  step when this network is next started from scratch.
- `getBalances` returns a zeroed `XmrBalanceInfo` (no funds on a fresh local
  network) — correct behavior, printed as empty.
- The full trade flow (post/take offer, chats, disputes) was NOT exercised —
  that needs two funded accounts and is a follow-up, not a parity blocker.
