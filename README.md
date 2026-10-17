# haveno-dart

[![CI](https://github.com/Surbhu200/haveno-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/Surbhu200/haveno-dart/actions/workflows/ci.yml)

A Dart client for the [Haveno](https://haveno.exchange/) daemon — a port of
[haveno-ts](https://github.com/haveno-dex/haveno-ts) to native Dart gRPC.

Use it to talk to a running `haveno-daemon` from any Dart or Flutter
application: browse offers, post and take trades, manage the Monero wallet,
send trade chat messages, handle disputes, and receive server notifications.

## Status

- Full method parity with the haveno-ts `HavenoClient` (~85 public methods),
  including `PostOfferConfig` / `EditOfferConfig` and all wallet, offer, trade,
  dispute, connection, node and payment-account methods.
- Method parity verified by `tool/parity_check.py`, which generates
  `PARITY.md`: **87/87** public methods of haveno-ts's `HavenoClient.ts` are
  matched. The only Dart-only additions are the documented `close()` (gRPC
  channel shutdown) and a private notification helper.
- `dart analyze` clean; `dart test` **10/10 passing**: 3 unit tests plus 7
  in-process integration tests running a real gRPC server on localhost
  (unary calls, password metadata, account-exists/open reply mapping,
  server-streamed notifications, `awaitAppInitialized` via both the
  notification and the already-initialized path, `createAccount`).
- **Verified against a real `haveno-daemon` v1.11.0** on a local XMR_LOCAL
  network: version/connection, account lifecycle, 79 payment methods, wallet
  and offer calls, and honest error propagation — full transcript in
  `LIVE_DAEMON_TEST.md`. (Full multi-party trade flow not yet exercised.)

## Requirements

- Dart SDK 3.x
- A running Haveno daemon with the gRPC API enabled and an `--apiPassword` set
  (default native gRPC port: **8079**)

## Usage

Add the dependency (path or git):

```yaml
dependencies:
  haveno_dart:
    path: ../haveno-dart
```

```dart
import 'package:haveno_dart/haveno_dart.dart';

Future<void> main() async {
  final client = HavenoClient('http://localhost:8079', 'apiPassword');
  try {
    print(await client.getVersion());
    final offers = await client.getOffers('USD', OfferDirection.BUY);
    print('${offers.length} offers to buy XMR for USD');
  } finally {
    await client.close(); // closes the gRPC channel; the daemon keeps running
  }
}
```

See `example/haveno_dart_example.dart` for a fuller example.

## Architecture notes

- The port uses `package:grpc` and connects to the daemon's **native gRPC port
  directly** (default 8079). haveno-ts, being browser-friendly, speaks grpc-web
  through an Envoy proxy (default 8080); that proxy is not needed here.
- The daemon API password is sent as gRPC metadata (`password`) on every call.
- `HavenoClient.startProcess(...)` can spawn a `haveno-daemon` binary and
  resolves as soon as the log line "Application fully initialized" (or
  "Interactive login required") appears.
- `close()` is Dart-specific: native gRPC keeps a socket open until the channel
  is shut down, which would otherwise keep a Dart process alive.
- Notifications are consumed as a server-stream; cancelling the stream
  subscription unregisters the client, and a keep-alive request is sent every
  60 s while listeners are attached.

## Regenerating the protobuf bindings

The bindings in `lib/src/generated/` are generated from the official Haveno
`.proto` files (copied to `proto/`):

```sh
protoc -I proto proto/pb.proto proto/grpc.proto --dart_out=grpc:lib/src/generated
```

The output must be produced with **protoc_plugin 22.x** (protobuf 4.x
compatible). Newer protoc_plugin releases (25.x) emit code that does not
compile against `protobuf` 4.x.

## Tests

```sh
dart pub get
dart analyze
dart test
```

## License

Apache License 2.0 — see `LICENSE`. This package is a Dart port of
haveno-ts, which is licensed under the same terms.

## Ported from

- `HavenoClient.ts` → `lib/src/haveno_client.dart`
- `HavenoUtils.ts` → `lib/src/haveno_utils.dart`
- `TaskLooper.ts` → `lib/src/task_looper.dart`
- `HavenoError.ts` → `lib/src/haveno_error.dart`
