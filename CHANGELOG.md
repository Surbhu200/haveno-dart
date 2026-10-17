# Changelog

## 0.1.0

- Initial Dart port of haveno-ts `HavenoClient` (~85 public methods) including
  `PostOfferConfig` and `EditOfferConfig`.
- Ported `HavenoUtils`, `TaskLooper` and `HavenoError`.
- Generated protobuf/gRPC bindings from the official Haveno `.proto` files
  (protoc_plugin 22.x, protobuf 4.x compatible).
- Unit tests for client construction and utility conversions; `dart analyze`
  clean.
- Dart-specific addition: `HavenoClient.close()` to shut down the underlying
  gRPC channel.
