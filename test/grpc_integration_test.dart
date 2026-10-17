import 'dart:async';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';
import 'package:haveno_dart/haveno_dart.dart';
import 'package:test/test.dart';

/// Fake GetVersion service that records the password metadata it received.
class FakeVersion extends GetVersionServiceBase {
  String? receivedPassword;

  @override
  Future<GetVersionReply> getVersion(ServiceCall call, GetVersionRequest request) async {
    receivedPassword = call.clientMetadata?['password'];
    return GetVersionReply()..version = '1.0.0-test';
  }
}

/// Fake Notifications service emitting one APP_INITIALIZED message per listener.
class FakeNotifications extends NotificationsServiceBase {
  String? receivedPassword;

  @override
  Stream<NotificationMessage> registerNotificationListener(
      ServiceCall call, RegisterNotificationListenerRequest request) {
    receivedPassword = call.clientMetadata?['password'];
    return Stream.fromFuture(Future.delayed(
      const Duration(milliseconds: 300),
      () => NotificationMessage()
        ..type = NotificationMessage_NotificationType.APP_INITIALIZED
        ..timestamp = Int64(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  @override
  Future<SendNotificationReply> sendNotification(ServiceCall call, SendNotificationRequest request) async =>
      SendNotificationReply();

  @override
  Future<GetAlertReply> getAlert(ServiceCall call, GetAlertRequest request) async => GetAlertReply();
}

/// Fake Account service: configurable initialization/account flags; records the
/// passwords sent through CreateAccount/OpenAccount.
class FakeAccount extends AccountServiceBase {
  FakeAccount({
    this.appInitialized = false,
    this.accountExistsInDaemon = true,
    this.accountOpenInDaemon = true,
  });

  bool appInitialized;
  bool accountExistsInDaemon;
  bool accountOpenInDaemon;
  String? createdWithPassword;
  String? openedWithPassword;

  @override
  Future<AccountExistsReply> accountExists(ServiceCall call, AccountExistsRequest request) async =>
      AccountExistsReply()..accountExists = accountExistsInDaemon;

  @override
  Future<IsAccountOpenReply> isAccountOpen(ServiceCall call, IsAccountOpenRequest request) async =>
      IsAccountOpenReply()..isAccountOpen = accountOpenInDaemon;

  @override
  Future<IsAppInitializedReply> isAppInitialized(ServiceCall call, IsAppInitializedRequest request) async =>
      IsAppInitializedReply()..isAppInitialized = appInitialized;

  @override
  Future<CreateAccountReply> createAccount(ServiceCall call, CreateAccountRequest request) async {
    createdWithPassword = request.password;
    return CreateAccountReply();
  }

  @override
  Future<OpenAccountReply> openAccount(ServiceCall call, OpenAccountRequest request) async {
    openedWithPassword = request.password;
    return OpenAccountReply();
  }

  @override
  Future<ChangePasswordReply> changePassword(ServiceCall call, ChangePasswordRequest request) async =>
      ChangePasswordReply();

  @override
  Future<CloseAccountReply> closeAccount(ServiceCall call, CloseAccountRequest request) async => CloseAccountReply();

  @override
  Future<DeleteAccountReply> deleteAccount(ServiceCall call, DeleteAccountRequest request) async => DeleteAccountReply();

  @override
  Stream<BackupAccountReply> backupAccount(ServiceCall call, BackupAccountRequest request) => const Stream.empty();

  @override
  Future<RestoreAccountReply> restoreAccount(ServiceCall call, RestoreAccountRequest request) async =>
      RestoreAccountReply();
}

void main() {
  late Server server;
  late FakeVersion version;
  late FakeNotifications notifications;
  late FakeAccount account;
  late HavenoClient client;
  const password = 'secret-api-pass';

  setUp(() async {
    version = FakeVersion();
    notifications = FakeNotifications();
    account = FakeAccount();
    server = Server.create(services: [version, notifications, account]);
    await server.serve(address: '127.0.0.1', port: 0);
    client = HavenoClient('http://127.0.0.1:${server.port}', password);
  });

  tearDown(() async {
    await client.close();
    await server.shutdown();
  });

  test('getVersion calls the daemon over real gRPC', () async {
    expect(await client.getVersion(), '1.0.0-test');
  });

  test('the api password is sent as gRPC metadata on every call', () async {
    await client.getVersion();
    expect(version.receivedPassword, password);
  });

  test('accountExists / isAccountOpen map daemon reply fields', () async {
    expect(await client.accountExists(), isTrue);
    expect(await client.isAccountOpen(), isTrue);

    account.accountExistsInDaemon = false;
    account.accountOpenInDaemon = false;
    expect(await client.accountExists(), isFalse);
    expect(await client.isAccountOpen(), isFalse);
  });

  test('addNotificationListener receives server-streamed notifications', () async {
    final got = Completer<NotificationMessage>();
    void listener(NotificationMessage n) {
      if (!got.isCompleted) got.complete(n);
    }

    await client.addNotificationListener(listener);
    final notification = await got.future.timeout(const Duration(seconds: 5));
    expect(notification.type, NotificationMessage_NotificationType.APP_INITIALIZED);
    expect(notifications.receivedPassword, password);

    await client.removeNotificationListener(listener);
  });

  test('awaitAppInitialized resolves via notification when not yet initialized', () async {
    expect(account.appInitialized, isFalse);
    await client.awaitAppInitialized().timeout(const Duration(seconds: 5));
  });

  test('awaitAppInitialized returns immediately when already initialized', () async {
    account.appInitialized = true;
    await client.awaitAppInitialized().timeout(const Duration(seconds: 5));
  });

  test('createAccount awaits initialization and sends the account password', () async {
    await client.createAccount('hunter2').timeout(const Duration(seconds: 5));
    expect(account.createdWithPassword, 'hunter2');
  });
}
