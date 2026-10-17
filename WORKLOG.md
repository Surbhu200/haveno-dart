# Haveno Dart Port - Worklog

## Status

- `dart analyze` -> **No issues found!**
- `dart test` -> **10/10 passing**: 3 unit tests (client construction/getUrl, empty-url error, XMR->atomic units) plus 7 in-process gRPC integration tests (`test/grpc_integration_test.dart`) that start a real `package:grpc` `Server` on localhost and exercise the client over the wire: unary `getVersion`, password sent as gRPC metadata, `accountExists`/`isAccountOpen` reply mapping, server-streamed notifications, `awaitAppInitialized` via both paths (notification and already-initialized), and `createAccount` (password + init wait).
- **Live-daemon smoke test PASSED** against `haveno-daemon` v1.11.0 (local XMR_LOCAL docker network): getVersion, connection, account lifecycle, 79 payment methods, balances/offers/stats, `HavenoError(2)` propagation — see `LIVE_DAEMON_TEST.md`. Full multi-party trade flow still untested.

## Architecture notes

- This package is a Dart port of `haveno-ts/src/HavenoClient.ts` (`C:\Users\bachu\Downloads\OpenCode\haveno-ts`).
- Transport: **native gRPC** via `package:grpc` (grpc 4.2.0) and `package:protobuf` (protobuf 4.2.0),
  using `ClientChannel(host, port, options: ChannelOptions(credentials: ...))`:
  - `http://` URLs (the common case) use `ChannelCredentials.insecure()` and default to port **8079**;
  - `https://` URLs use `ChannelCredentials.secure()` and default to port 443.
- The client talks to the daemon's native gRPC endpoint **directly**. (haveno-ts instead speaks
  grpc-web through the Envoy proxy on port 8080; this port skips Envoy entirely.)
- The API password is sent with every RPC as `CallOptions(metadata: {'password': password})`.
- Notifications use the server-streaming `RegisterNotificationListener` call with client-side
  keep-alives sent by a `TaskLooper`.
- Generated protobuf/gRPC code lives in `lib/src/generated/` and must not be hand-edited.

## Ported files

| File | Status |
| --- | --- |
| `pubspec.yaml` | Done - grpc ^4.0.1 (resolved 4.2.0), protobuf ^4.1.0 (resolved 4.2.0), fixnum, decimal ^3.0.2, collection, meta; dev: lints, test |
| `analysis_options.yaml` | Done - `package:lints/recommended`, generated-name lints disabled |
| `lib/haveno_dart.dart` | Done - public exports |
| `lib/src/task_looper.dart` | Done - fixed-period task loop (`start`/`stop`, optional fixed-period targeting) |
| `lib/src/haveno_error.dart` | Done - `HavenoError(message, [code])` |
| `lib/src/haveno_utils.dart` | Done - log levels/timestamps, `kill`, XMR<->atomic conversions (via `decimal`), payment account form helpers |
| `lib/src/haveno_client.dart` | Done - full API port: version/init, account, XMR connections + node, dispute agents + disputes, wallet, prices, payment accounts, offers, trades, notifications, process lifecycle |
| `lib/src/generated/*` | Generated (7 files: `pb.pb/pbenum/pbjson`, `grpc.pb/pbenum/pbgrpc/pbjson`) - do not edit |
| `test/haveno_client_test.dart` | Done - 3 unit tests |
| `test/grpc_integration_test.dart` | Done - 7 in-process real-gRPC tests (unary, auth metadata, account replies, server-streamed notifications, awaitAppInitialized both paths, createAccount) |
| `tool/parity_check.py` + `PARITY.md` | Done - method-parity checker (87/87 haveno-ts methods matched; Dart-only: `close`, `_onNotification`) |

## Proto regeneration

`lib/src/generated/` was generated with protoc_plugin **22.5.0** (the last 22.x release, whose output
targets protobuf 4.x). protoc_plugin 23+ requires protobuf 5.x and 25.x requires protobuf 6.x, and its
output will **not** compile against this package's protobuf ^4.1.0 / grpc ^4.x constraints.

```sh
dart pub global activate protoc_plugin 22.5.0
protoc -I proto proto/pb.proto proto/grpc.proto --dart_out=grpc:lib/src/generated
```

## Fixes applied during verification

- **Regenerated `lib/src/generated/`**: the checked-in files were protoc_plugin 25.1.0 output
  (`$_createMessage`, shorthand `aI/aD/aE/pPM` builders, deprecated `create()`), which does not
  compile against protobuf 4.2.0. Regenerated with protoc_plugin 22.5.0.
- **`proto/pb.proto`**: wrapped `trade:<uid>` / `offer:<id>` in backticks in the `TradableLogEntry`
  comment so generated dartdoc no longer trips `unintended_html_in_doc_comment`.
- **`lib/src/haveno_client.dart`**:
  - Constructor: `_url` / `_password` are `final`; they are now initialized in the initializer list
    instead of the constructor body (`final_not_initialized_constructor`, `assignment_to_final`).
  - `awaitAppInitialized()`: declared the notification `listener` before `resolveOnce` (as a
    `late final` local closure) to fix `referenced_before_declaration`.
  - `backupAccount()`: protobuf 4.x bytes getters return `List<int>`; chunks are wrapped with
    `Uint8List.fromList` to satisfy `void Function(Uint8List)` (`argument_type_not_assignable`).
  - `getMyOffers()`: builds a `GetMyOffersRequest` (the generated `OffersClient` requires it; the
    haveno-ts code passed `GetOffersRequest` against its old grpc-web stubs) (`argument_type_not_assignable`).
  - `_toHavenoError()`: grpc 4.x `GrpcError` exposes non-nullable `int code` (no `.value`) and
    `String? message`; now `HavenoError(e.message ?? 'gRPC error', e.code)`.
  - `startProcess()`: both `return completer.future` sites changed to `return await ...` inside the
    try block (`unawaited_return_in_try_block`), so startup failures surface as `HavenoError`;
    removed a redundant `!` in `rejectStartup` (`unnecessary_non_null_assertion`).
  - Minor lint cleanups: `_keepAlivePeriodMs` is `final`, `restoreAccount()` uses `zipBytes.isEmpty`,
    `getPaymentMethods()` uses `??=`, removed the redundant `generated/grpc.pb.dart` import
    (re-exported by `grpc.pbgrpc.dart`).

## Port notes

- `startProcess` resolves the returned future when the daemon prints `Application fully initialized`
  (or `Interactive login required`) on stdout; the API password is read from the `--apiPassword`
  argument, and `--appName` / `--walletRpcBindPort` are captured when present.
  `[HavenoDaemonMain] ERROR` lines reject startup before initialization; an early process exit
  rejects with the captured output.
- Node's `uncaughtException` handler from haveno-ts was intentionally dropped: Dart has no
  equivalent global handler, and errors are surfaced through futures instead.
- `HavenoUtils.kill` uses `taskkill /PID <pid> /T /F` on Windows and `ProcessSignal.sigint`
  elsewhere.

## Remaining work

- Full trade flow end-to-end (post/take offer, chats, disputes) — needs two
  funded accounts on the live network. Basic live-daemon run already passed
  (`LIVE_DAEMON_TEST.md`).
- Publish to a public repository (helper: `publish.ps1`).
