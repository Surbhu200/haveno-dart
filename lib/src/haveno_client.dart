/*
 * Copyright Haveno
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:grpc/grpc.dart';

import 'generated/grpc.pbgrpc.dart';
import 'generated/pb.pb.dart';
import 'haveno_error.dart';
import 'haveno_utils.dart';
import 'task_looper.dart';

/// Configuration to post or clone an offer.
class PostOfferConfig {
  OfferDirection? direction;
  BigInt? amount;
  BigInt? minAmount;
  String? assetCode;
  String? paymentAccountId;
  double? securityDepositPct;
  double? price;
  double? marketPriceMarginPct;
  double? triggerPrice;
  bool reserveExactAmount;
  bool isPrivateOffer;
  bool buyerAsTakerWithoutDeposit;
  String? extraInfo;
  String? sourceOfferId;

  PostOfferConfig({
    this.direction,
    this.amount,
    this.minAmount,
    this.assetCode,
    this.paymentAccountId,
    this.securityDepositPct,
    this.price,
    this.marketPriceMarginPct,
    this.triggerPrice,
    this.reserveExactAmount = false,
    this.isPrivateOffer = false,
    this.buyerAsTakerWithoutDeposit = false,
    this.extraInfo,
    this.sourceOfferId,
  });
}

/// Configuration to edit an offer.
class EditOfferConfig {
  String offerId;
  String? assetCode;
  String? paymentAccountId;
  double? price;
  double? marketPriceMarginPct;
  double? triggerPrice;
  String? extraInfo;

  EditOfferConfig({
    required this.offerId,
    this.assetCode,
    this.paymentAccountId,
    this.price,
    this.marketPriceMarginPct,
    this.triggerPrice,
    this.extraInfo,
  });
}

/// Haveno daemon client.
class HavenoClient {
  // grpc clients
  late final ClientChannel _channel;
  late final GetTradeStatisticsClient _getTradeStatisticsClient;
  late final GetVersionClient _getVersionClient;
  late final AccountClient _accountClient;
  late final XmrConnectionsClient _xmrConnectionsClient;
  late final XmrNodeClient _xmrNodeClient;
  late final DisputeAgentsClient _disputeAgentsClient;
  late final DisputesClient _disputesClient;
  late final WalletsClient _walletsClient;
  late final PriceClient _priceClient;
  late final PaymentAccountsClient _paymentAccountsClient;
  late final OffersClient _offersClient;
  late final TradesClient _tradesClient;
  late final NotificationsClient _notificationsClient;
  late final ShutdownServerClient _shutdownServerClient;

  // state variables
  final String _url;
  final String _password;
  Process? _process;
  bool _processLogging = false;
  int? _walletRpcPort;
  String? _appName;
  final List<void Function(NotificationMessage)> _notificationListeners = [];
  ResponseStream<NotificationMessage>? _notificationStream;
  StreamSubscription<NotificationMessage>? _notificationSubscription;
  TaskLooper? _keepAliveLooper;
  final int _keepAlivePeriodMs = 60000;
  List<PaymentMethod>? _paymentMethods; // cached for performance
  late final CallOptions _options;

  // constants
  static const String _fullyInitializedMessage = 'Application fully initialized';
  static const String _loginRequiredMessage = 'Interactive login required';

  /// Construct a client connected to a Haveno daemon.
  ///
  /// [url] - Haveno daemon url (e.g. http://localhost:8079)
  /// [password] - Haveno daemon api password
  HavenoClient(String url, String password)
      : _url = url,
        _password = password {
    if (url.isEmpty) throw HavenoError('Must provide URL of Haveno daemon');
    if (password.isEmpty) throw HavenoError('Must provide password of Haveno daemon');
    HavenoUtils.log(2, 'Creating Haveno client connected to $url');
    final uri = Uri.parse(url.contains('://') ? url : 'http://$url');
    final secure = uri.scheme == 'https';
    _channel = ClientChannel(
      uri.host,
      port: uri.hasPort ? uri.port : (secure ? 443 : 8079),
      options: ChannelOptions(
        credentials: secure ? ChannelCredentials.secure() : ChannelCredentials.insecure(),
      ),
    );
    _options = CallOptions(metadata: {'password': _password});
    _getTradeStatisticsClient = GetTradeStatisticsClient(_channel);
    _getVersionClient = GetVersionClient(_channel);
    _accountClient = AccountClient(_channel);
    _xmrConnectionsClient = XmrConnectionsClient(_channel);
    _xmrNodeClient = XmrNodeClient(_channel);
    _disputeAgentsClient = DisputeAgentsClient(_channel);
    _disputesClient = DisputesClient(_channel);
    _walletsClient = WalletsClient(_channel);
    _priceClient = PriceClient(_channel);
    _paymentAccountsClient = PaymentAccountsClient(_channel);
    _offersClient = OffersClient(_channel);
    _tradesClient = TradesClient(_channel);
    _notificationsClient = NotificationsClient(_channel);
    _shutdownServerClient = ShutdownServerClient(_channel);
  }

  /// Start a new Haveno process.
  ///
  /// [havenoPath] - path to Haveno binaries
  /// [cmd] - command to start the process
  /// [url] - Haveno daemon url
  /// [enableLogging] - specifies if logging is enabled or disabled at log level 3
  /// Returns a client connected to the newly started Haveno process.
  static Future<HavenoClient> startProcess(String havenoPath, List<String> cmd, String url, bool enableLogging) async {
    try {
      HavenoUtils.log(2, 'Starting Haveno process: $cmd on proxy url: $url');
      var output = '';
      var isStarted = false;
      HavenoClient? daemon;
      Process? childProcess;
      final completer = Completer<HavenoClient>();

      bool loggingEnabled() => (daemon != null && daemon!._processLogging) || (daemon == null && enableLogging);

      Future<void> rejectStartup(Object err) async {
        if (childProcess != null) await HavenoUtils.kill(childProcess);
        if (!completer.isCompleted) completer.completeError(err);
      }

      try {
        childProcess = await Process.start(cmd.first, cmd.sublist(1),
            workingDirectory: havenoPath, runInShell: Platform.isWindows);
      } catch (err) {
        if (err is ProcessException && err.message.toUpperCase().contains('ENOENT')) {
          if (!completer.isCompleted) {
            completer.completeError(Exception("haveno-daemon does not exist at path '${cmd.first}'"));
          }
        } else {
          if (!completer.isCompleted) completer.completeError(err);
        }
        return await completer.future;
      }

      childProcess.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
        if (loggingEnabled()) stdout.write('$line\n');
        output += '$line\n';

        // initialize daemon on success or login required message
        if (daemon == null && (line.contains(_fullyInitializedMessage) || line.contains(_loginRequiredMessage))) {
          // get api password
          final passwordIdx = cmd.indexOf('--apiPassword');
          if (passwordIdx < 0) {
            await rejectStartup('Must provide API password to start Haveno daemon');
            return;
          }
          final password = cmd[passwordIdx + 1];

          // create client connected to internal process
          daemon = HavenoClient(url, password);
          daemon!._process = childProcess;
          daemon!._processLogging = enableLogging;
          final appNameIdx = cmd.indexOf('--appName');
          if (appNameIdx >= 0) daemon!._appName = cmd[appNameIdx + 1];

          // get wallet rpc port
          final walletRpcPortIdx = cmd.indexOf('--walletRpcBindPort');
          if (walletRpcPortIdx >= 0) daemon!._walletRpcPort = int.parse(cmd[walletRpcPortIdx + 1]);

          // resolve promise with client connected to internal process
          isStarted = true;
          if (!completer.isCompleted) completer.complete(daemon);
        }

        // read error message
        if (line.contains('[HavenoDaemonMain] ERROR')) {
          if (!isStarted) await rejectStartup(Exception(line));
        }
      });

      childProcess.stderr.transform(utf8.decoder).listen((data) {
        if (loggingEnabled()) stderr.write(data);
      });

      unawaited(childProcess.exitCode.then((code) async {
        if (!isStarted && !completer.isCompleted) {
          await rejectStartup(Exception(
              'Haveno process terminated with exit code $code${output.isNotEmpty ? ':\n\n$output' : ''}'));
        }
      }));

      return await completer.future;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Return the process running the haveno daemon.
  Process? getProcess() => _process;

  /// Enable or disable process logging.
  void setProcessLogging(bool enabled) {
    if (_process == null) throw HavenoError('haveno instance not created from new process');
    _processLogging = enabled;
  }

  /// Get the URL of the Haveno daemon.
  String getUrl() => _url;

  /// Get the port of the primary wallet rpc instance if known.
  int? getWalletRpcPort() => _walletRpcPort;

  /// Get the name of the Haveno application folder.
  String? getAppName() => _appName;

  /// Get the Haveno version.
  Future<String> getVersion() async {
    try {
      return (await _getVersionClient.getVersion(GetVersionRequest(), options: _options)).version;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Check whether the application is fully initialized with an account and a
  /// connection to the Haveno network.
  Future<bool> isAppInitialized() async {
    try {
      return (await _accountClient.isAppInitialized(IsAppInitializedRequest(), options: _options)).isAppInitialized;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Wait for the application to be fully initialized with an account and a
  /// connection to the Haveno network.
  Future<void> awaitAppInitialized() async {
    try {
      final completer = Completer<void>();
      var isResolved = false;

      late final void Function(NotificationMessage) listener;

      Future<void> resolveOnce() async {
        if (isResolved) return;
        isResolved = true;
        await removeNotificationListener(listener);
        if (!completer.isCompleted) completer.complete();
      }

      listener = (notification) {
        if (notification.type == NotificationMessage_NotificationType.APP_INITIALIZED) resolveOnce();
      };

      await addNotificationListener(listener);
      if (await isAppInitialized()) await resolveOnce();
      await completer.future;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Indicates if connected and authenticated with the Haveno daemon.
  Future<bool> isConnectedToDaemon() async {
    try {
      await getVersion();
      return true;
    } catch (err) {
      return false;
    }
  }

  /// Indicates if the Haveno account is created.
  Future<bool> accountExists() async {
    try {
      return (await _accountClient.accountExists(AccountExistsRequest(), options: _options)).accountExists;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Indicates if the Haveno account is open and authenticated with the correct password.
  Future<bool> isAccountOpen() async {
    try {
      return (await _accountClient.isAccountOpen(IsAccountOpenRequest(), options: _options)).isAccountOpen;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Create and open a new Haveno account.
  ///
  /// [password] - the password to encrypt the account
  Future<void> createAccount(String password) async {
    try {
      await _accountClient.createAccount(CreateAccountRequest()..password = password, options: _options);
      await awaitAppInitialized();
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Open existing Haveno account.
  ///
  /// [password] - the account password
  Future<void> openAccount(String password) async {
    try {
      await _accountClient.openAccount(OpenAccountRequest()..password = password, options: _options);
      await awaitAppInitialized();
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Change the Haveno account password.
  Future<void> changePassword(String oldPassword, String newPassword) async {
    try {
      final request = ChangePasswordRequest()
        ..oldPassword = oldPassword
        ..newPassword = newPassword;
      await _accountClient.changePassword(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Close the currently open account.
  Future<void> closeAccount() async {
    try {
      await _accountClient.closeAccount(CloseAccountRequest(), options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Permanently delete the Haveno account.
  Future<void> deleteAccount() async {
    try {
      await _accountClient.deleteAccount(DeleteAccountRequest(), options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Backup the account, writing chunks of zip bytes to [write].
  /// Returns the total number of bytes written.
  Future<int> backupAccount(void Function(Uint8List chunk) write) async {
    try {
      var total = 0;
      final stream = _accountClient.backupAccount(BackupAccountRequest(), options: _options);
      await for (final reply in stream) {
        final bytes = Uint8List.fromList(reply.zipBytes);
        total += bytes.length;
        write(bytes);
      }
      return total;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Restore the account from zip bytes.
  ///
  /// Sends chunked requests if size over max grpc envelope size (41943404 bytes).
  Future<void> restoreAccount(Uint8List zipBytes) async {
    if (zipBytes.isEmpty) throw HavenoError('Zip bytes must not be empty');
    final totalLength = zipBytes.length;
    var offset = 0;
    var chunkSize = 4000000; // the max frame size is 4194304 but leave room for http headers
    var hasMore = true;
    while (true) {
      if (zipBytes.length <= offset + 1) return;
      if (zipBytes.length <= offset + chunkSize) {
        chunkSize = zipBytes.length - offset - 1;
        hasMore = false;
      }
      final subArray = Uint8List.sublistView(zipBytes, offset, offset + chunkSize);
      await _restoreAccountChunk(subArray, offset, totalLength, hasMore);
      offset += chunkSize;
    }
  }

  /// Add a listener to receive notifications from the Haveno daemon.
  Future<void> addNotificationListener(void Function(NotificationMessage) listener) async {
    _notificationListeners.add(listener);
    await _updateNotificationListenerRegistration();
  }

  /// Remove a notification listener.
  Future<void> removeNotificationListener(void Function(NotificationMessage) listener) async {
    final idx = _notificationListeners.indexOf(listener);
    if (idx > -1) {
      _notificationListeners.removeAt(idx);
    } else {
      throw HavenoError('Notification listener is not registered');
    }
    await _updateNotificationListenerRegistration();
  }

  /// Indicates if connected to the Monero network based on last connection check.
  Future<bool> isConnectedToMonero() async {
    final connection = await getMoneroConnection();
    return connection != null &&
        connection.onlineStatus == UrlConnection_OnlineStatus.ONLINE &&
        connection.authenticationStatus != UrlConnection_AuthenticationStatus.NOT_AUTHENTICATED;
  }

  /// Add a Monero daemon connection.
  ///
  /// [connection] - daemon url string or UrlConnection to add
  Future<void> addMoneroConnection(Object connection) async {
    try {
      final conn = connection is String ? (UrlConnection()..url = connection) : connection as UrlConnection;
      await _xmrConnectionsClient.addConnection(AddConnectionRequest()..connection = conn, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Remove a Monero daemon connection.
  Future<void> removeMoneroConnection(String url) async {
    try {
      await _xmrConnectionsClient.removeConnection(RemoveConnectionRequest()..url = url, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the current Monero daemon connection.
  Future<UrlConnection?> getMoneroConnection() async {
    try {
      final reply = await _xmrConnectionsClient.getConnection(GetConnectionRequest(), options: _options);
      return reply.hasConnection() ? reply.connection : null;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all Monero daemon connections.
  Future<List<UrlConnection>> getMoneroConnections() async {
    try {
      return (await _xmrConnectionsClient.getConnections(GetConnectionsRequest(), options: _options)).connections;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Set the current Monero daemon connection.
  ///
  /// Add the connection if not previously seen.
  /// If the connection is provided as string, connect to the URI with any
  /// previously set credentials and priority.
  /// If the connection is provided as UrlConnection, overwrite any previously
  /// set credentials and priority.
  /// If no connection is provided, disconnect the client.
  Future<void> setMoneroConnection([Object? connection]) async {
    final request = SetConnectionRequest();
    if (connection is String) {
      request.url = connection;
    } else if (connection is UrlConnection) {
      request.connection = connection;
    }
    try {
      await _xmrConnectionsClient.setConnection(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Check the current Monero daemon connection.
  ///
  /// If disconnected and auto switch enabled, switch to the best available
  /// connection and return its status.
  Future<UrlConnection?> checkMoneroConnection() async {
    try {
      final reply = await _xmrConnectionsClient.checkConnection(CheckConnectionRequest(), options: _options);
      return reply.hasConnection() ? reply.connection : null;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the best connection in order of priority then response time.
  Future<UrlConnection?> getBestConnection() async {
    try {
      final reply = await _xmrConnectionsClient.getBestConnection(GetBestConnectionRequest(), options: _options);
      return reply.hasConnection() ? reply.connection : null;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Automatically switch to the best available connection if current
  /// connection is disconnected after being checked.
  Future<void> setAutoSwitch(bool autoSwitch) async {
    try {
      await _xmrConnectionsClient.setAutoSwitch(SetAutoSwitchRequest()..autoSwitch = autoSwitch, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the current auto switch setting.
  Future<bool> getAutoSwitch() async {
    try {
      return (await _xmrConnectionsClient.getAutoSwitch(GetAutoSwitchRequest(), options: _options)).autoSwitch;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Returns whether daemon is running a local monero node.
  Future<bool> isMoneroNodeOnline() async {
    try {
      return (await _xmrNodeClient.isXmrNodeOnline(IsXmrNodeOnlineRequest(), options: _options)).isRunning;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Gets the current local monero node settings.
  Future<XmrNodeSettings?> getMoneroNodeSettings() async {
    try {
      final reply = await _xmrNodeClient.getXmrNodeSettings(GetXmrNodeSettingsRequest(), options: _options);
      return reply.hasSettings() ? reply.settings : null;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Starts the local monero node.
  Future<void> startMoneroNode(XmrNodeSettings settings) async {
    try {
      await _xmrNodeClient.startXmrNode(StartXmrNodeRequest()..settings = settings, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Stops the local monero node.
  Future<void> stopMoneroNode() async {
    try {
      await _xmrNodeClient.stopXmrNode(StopXmrNodeRequest(), options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Register as a dispute agent.
  ///
  /// [disputeAgentType] - type of dispute agent to register, e.g. mediator, refundagent
  /// [registrationKey] - registration key
  Future<void> registerDisputeAgent(String disputeAgentType, String registrationKey) async {
    try {
      final request = RegisterDisputeAgentRequest()
        ..disputeAgentType = disputeAgentType
        ..registrationKey = registrationKey;
      await _disputeAgentsClient.registerDisputeAgent(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Unregister as a dispute agent.
  Future<void> unregisterDisputeAgent(String disputeAgentType) async {
    try {
      await _disputeAgentsClient.unregisterDisputeAgent(UnregisterDisputeAgentRequest()..disputeAgentType = disputeAgentType, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get heights of the Monero wallet.
  Future<GetWalletHeightReply> getWalletHeights() async {
    try {
      return await _walletsClient.getHeight(GetWalletHeightRequest(), options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the user's balances.
  Future<XmrBalanceInfo> getBalances() async {
    try {
      return (await _walletsClient.getBalances(GetBalancesRequest()..currencyCode = 'XMR', options: _options)).balances.xmr;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the mnemonic seed phrase of the Monero wallet.
  Future<String> getXmrSeed() async {
    try {
      return (await _walletsClient.getXmrSeed(GetXmrSeedRequest(), options: _options)).seed;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the primary address of the Monero wallet.
  Future<String> getXmrPrimaryAddress() async {
    try {
      return (await _walletsClient.getXmrPrimaryAddress(GetXmrPrimaryAddressRequest(), options: _options)).primaryAddress;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a new subaddress in the Monero wallet to receive deposits.
  Future<String> getXmrNewSubaddress() async {
    try {
      return (await _walletsClient.getXmrNewSubaddress(GetXmrNewSubaddressRequest(), options: _options)).subaddress;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all transactions in the Monero wallet.
  Future<List<XmrTx>> getXmrTxs() async {
    try {
      return (await _walletsClient.getXmrTxs(GetXmrTxsRequest(), options: _options)).txs;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a transaction by hash in the Monero wallet.
  Future<XmrTx?> getXmrTx(String txHash) async {
    final txs = await getXmrTxs(); // TODO (woodser): implement getXmrTx(hash) grpc call
    for (final tx in txs) {
      if (tx.hash == txHash) return tx;
    }
    return null;
  }

  /// Create but do not relay a transaction to send funds from the Monero wallet.
  Future<XmrTx> createXmrTx(List<XmrDestination> destinations) async {
    try {
      return (await _walletsClient.createXmrTx(CreateXmrTxRequest()..destinations.addAll(destinations), options: _options)).tx;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Create but do not relay transactions to sweep all funds from the Monero wallet.
  Future<List<XmrTx>> createXmrSweepTxs(String address) async {
    try {
      return (await _walletsClient.createXmrSweepTxs(CreateXmrSweepTxsRequest()..address = address, options: _options)).txs;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Relay previously created transactions to send funds from the Monero wallet.
  Future<List<String>> relayXmrTxs(List<String> metadatas) async {
    try {
      return (await _walletsClient.relayXmrTxs(RelayXmrTxsRequest()..metadatas.addAll(metadatas), options: _options)).hashes;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all asset codes with price information.
  Future<List<String>> getPricedAssetCodes() async {
    final assetCodes = <String>[];
    for (final price in await getPrices()) {
      assetCodes.add(price.currencyCode);
    }
    return assetCodes;
  }

  /// Get the current market price per 1 XMR in the given currency.
  Future<double?> getPrice(String assetCode) async {
    try {
      return (await _priceClient.getMarketPrice(MarketPriceRequest()..currencyCode = assetCode, options: _options)).price;
    } catch (e) {
      final msg = e.toString();
      if (msg.contains('not found') || msg.contains('not available')) return null;
      throw _toHavenoError(e);
    }
  }

  /// Get the current market prices of all assets.
  Future<List<MarketPriceInfo>> getPrices() async {
    try {
      return (await _priceClient.getMarketPrices(MarketPricesRequest(), options: _options)).marketPrice;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the market depth of a currency.
  Future<MarketDepthInfo> getMarketDepth(String assetCode) async {
    try {
      return (await _priceClient.getMarketDepth(MarketDepthRequest()..currencyCode = assetCode, options: _options)).marketDepth;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get payment methods.
  Future<List<PaymentMethod>> getPaymentMethods([String? assetCode]) async {
    try {
      _paymentMethods ??= (await _paymentAccountsClient.getPaymentMethods(GetPaymentMethodsRequest(), options: _options)).paymentMethods;
      if (assetCode == null) return _paymentMethods!;
      final assetPaymentMethods = <PaymentMethod>[];
      for (final paymentMethod in _paymentMethods!) {
        if (paymentMethod.supportedAssetCodes.contains(assetCode)) assetPaymentMethods.add(paymentMethod);
      }
      return assetPaymentMethods;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get payment accounts.
  Future<List<PaymentAccount>> getPaymentAccounts() async {
    try {
      return (await _paymentAccountsClient.getPaymentAccounts(GetPaymentAccountsRequest(), options: _options)).paymentAccounts;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a payment account by id.
  Future<PaymentAccount> getPaymentAccount(String paymentAccountId) async {
    // TODO (woodser): implement this on the backend
    final paymentAccounts = await getPaymentAccounts();
    for (final paymentAccount in paymentAccounts) {
      if (paymentAccount.id == paymentAccountId) return paymentAccount;
    }
    throw HavenoError('No payment account with id $paymentAccountId');
  }

  /// Get a form for the given payment method to complete and create a new payment account.
  ///
  /// [paymentMethodId] - string or PaymentAccountForm_FormId of the payment method
  Future<PaymentAccountForm> getPaymentAccountForm(Object paymentMethodId) async {
    try {
      final methodId = HavenoUtils.getPaymentMethodId(paymentMethodId); // validate and normalize
      return (await _paymentAccountsClient.getPaymentAccountForm(GetPaymentAccountFormRequest()..paymentMethodId = methodId, options: _options)).paymentAccountForm;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a form from the given payment account payload.
  Future<PaymentAccountForm> getPaymentAccountPayloadForm(PaymentAccountPayload paymentAccountPayload) async {
    try {
      return (await _paymentAccountsClient.getPaymentAccountForm(GetPaymentAccountFormRequest()..paymentAccountPayload = paymentAccountPayload, options: _options)).paymentAccountForm;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Validate a form field.
  Future<void> validateFormField(PaymentAccountForm form, PaymentAccountFormField_FieldId fieldId, String value) async {
    final request = ValidateFormFieldRequest()
      ..form = form
      ..fieldId = fieldId
      ..value = value;
    try {
      await _paymentAccountsClient.validateFormField(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Create a payment account.
  Future<PaymentAccount> createPaymentAccount(PaymentAccountForm paymentAccountForm) async {
    try {
      return (await _paymentAccountsClient.createPaymentAccount(CreatePaymentAccountRequest()..paymentAccountForm = paymentAccountForm, options: _options)).paymentAccount;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Create a crypto payment account.
  ///
  /// [instant] - whether to use instant trades (default false)
  Future<PaymentAccount> createCryptoPaymentAccount(String accountName, String assetCode, String address, {bool? instant}) async {
    try {
      final request = CreateCryptoCurrencyPaymentAccountRequest()
        ..accountName = accountName
        ..currencyCode = assetCode
        ..address = address;
      if (instant != null) request.tradeInstant = instant;
      return (await _paymentAccountsClient.createCryptoCurrencyPaymentAccount(request, options: _options)).paymentAccount;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Delete a payment account.
  Future<void> deletePaymentAccount(String paymentAccountId) async {
    try {
      await _paymentAccountsClient.deletePaymentAccount(DeletePaymentAccountRequest()..paymentAccountId = paymentAccountId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get available offers to buy or sell XMR.
  ///
  /// [direction] - buy or sell (default all)
  Future<List<OfferInfo>> getOffers(String assetCode, [OfferDirection? direction]) async {
    try {
      if (direction == null) {
        return (await getOffers(assetCode, OfferDirection.BUY)) + (await getOffers(assetCode, OfferDirection.SELL)); // TODO: implement in backend
      }
      final request = GetOffersRequest()
        ..direction = direction == OfferDirection.BUY ? 'buy' : 'sell'
        ..currencyCode = assetCode;
      return (await _offersClient.getOffers(request, options: _options)).offers;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get the user's posted offers to buy or sell XMR.
  Future<List<OfferInfo>> getMyOffers([String? assetCode, OfferDirection? direction]) async {
    try {
      final req = GetMyOffersRequest();
      if (assetCode != null) req.currencyCode = assetCode;
      if (direction != null) req.direction = direction == OfferDirection.BUY ? 'buy' : 'sell';
      return (await _offersClient.getMyOffers(req, options: _options)).offers;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get my offer by id.
  Future<OfferInfo> getMyOffer(String offerId) async {
    try {
      return (await _offersClient.getMyOffer(GetMyOfferRequest()..id = offerId, options: _options)).offer;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Post or clone an offer.
  Future<OfferInfo> postOffer(PostOfferConfig config) async {
    HavenoUtils.log(2, 'Posting offer with security deposit %: ${config.securityDepositPct}');
    final request = PostOfferRequest();
    if (config.direction != null) request.direction = config.direction == OfferDirection.BUY ? 'buy' : 'sell';
    if (config.amount != null) request.amount = Int64.parseInt(config.amount!.toString());
    if (config.minAmount != null) {
      request.minAmount = Int64.parseInt(config.minAmount!.toString());
    } else if (config.amount != null) {
      request.minAmount = Int64.parseInt(config.amount!.toString());
    }
    if (config.assetCode != null) request.currencyCode = config.assetCode!;
    if (config.paymentAccountId != null) request.paymentAccountId = config.paymentAccountId!;
    if (config.securityDepositPct != null) request.securityDepositPct = config.securityDepositPct!;
    request.useMarketBasedPrice = config.price == null;
    if (config.price != null) request.price = config.price!.toString();
    if (config.marketPriceMarginPct != null) request.marketPriceMarginPct = config.marketPriceMarginPct!;
    if (config.triggerPrice != null) request.triggerPrice = config.triggerPrice!.toString();
    if (config.reserveExactAmount) request.reserveExactAmount = true;
    if (config.isPrivateOffer) request.isPrivateOffer = true;
    if (config.buyerAsTakerWithoutDeposit) request.buyerAsTakerWithoutDeposit = true;
    if (config.extraInfo != null) request.extraInfo = config.extraInfo!;
    if (config.sourceOfferId != null) request.sourceOfferId = config.sourceOfferId!;
    try {
      return (await _offersClient.postOffer(request, options: _options)).offer;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Edit an existing offer.
  Future<OfferInfo> editOffer(EditOfferConfig config) async {
    try {
      final request = EditOfferRequest()..offerId = config.offerId;
      if (config.assetCode != null) request.currencyCode = config.assetCode!;
      if (config.price != null) request.price = config.price!.toString();
      request.useMarketBasedPrice = config.price == null;
      request.marketPriceMarginPct = config.marketPriceMarginPct ?? 0;
      if (config.triggerPrice != null) request.triggerPrice = config.triggerPrice!.toString();
      if (config.paymentAccountId != null) request.paymentAccountId = config.paymentAccountId!;
      request.extraInfo = config.extraInfo ?? ''; // clear existing extra info if undefined
      return (await _offersClient.editOffer(request, options: _options)).offer;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Deactivate an offer.
  Future<void> deactivateOffer(String offerId) async {
    try {
      await _offersClient.deactivateOffer(DeactivateOfferRequest()..offerId = offerId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Activate an offer.
  Future<void> activateOffer(String offerId) async {
    try {
      await _offersClient.activateOffer(ActivateOfferRequest()..offerId = offerId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Remove a posted offer, releasing its reserved funds.
  Future<void> removeOffer(String offerId) async {
    try {
      await _offersClient.cancelOffer(CancelOfferRequest()..id = offerId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Take an offer.
  ///
  /// [amount] - amount the taker chooses to buy or sell within the offer range
  /// (default is max offer amount)
  /// [challenge] - the challenge to use for the private offer
  Future<TradeInfo> takeOffer(String offerId, String paymentAccountId, {BigInt? amount, String? challenge}) async {
    try {
      final request = TakeOfferRequest()
        ..offerId = offerId
        ..paymentAccountId = paymentAccountId;
      if (amount != null) request.amount = Int64.parseInt(amount.toString());
      if (challenge != null) request.challenge = challenge;
      final resp = await _tradesClient.takeOffer(request, options: _options);
      if (resp.hasTrade()) return resp.trade;
      throw HavenoError(resp.failureReason.description, resp.failureReason.availabilityResult.value);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a trade by id.
  Future<TradeInfo> getTrade(String tradeId) async {
    try {
      return (await _tradesClient.getTrade(GetTradeRequest()..tradeId = tradeId, options: _options)).trade;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all trade statistics.
  Future<List<TradeStatistics3>> getTradeStatistics() async {
    try {
      return (await _getTradeStatisticsClient.getTradeStatistics(GetTradeStatisticsRequest(), options: _options)).tradeStatistics;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get trades, optionally filtered by category.
  Future<List<TradeInfo>> getTrades([GetTradesRequest_Category? category]) async {
    try {
      final request = GetTradesRequest();
      if (category != null) request.category = category;
      return (await _tradesClient.getTrades(request, options: _options)).trades;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Confirm a payment is sent.
  Future<void> confirmPaymentSent(String tradeId) async {
    try {
      await _tradesClient.confirmPaymentSent(ConfirmPaymentSentRequest()..tradeId = tradeId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Confirm a payment is received.
  Future<void> confirmPaymentReceived(String tradeId) async {
    try {
      await _tradesClient.confirmPaymentReceived(ConfirmPaymentReceivedRequest()..tradeId = tradeId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Acknowledge that a trade has completed.
  Future<void> completeTrade(String tradeId) async {
    try {
      await _tradesClient.completeTrade(CompleteTradeRequest()..tradeId = tradeId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all chat messages for a trade.
  Future<List<ChatMessage>> getChatMessages(String tradeId) async {
    try {
      return (await _tradesClient.getChatMessages(GetChatMessagesRequest()..tradeId = tradeId, options: _options)).message;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Send a trade chat message.
  Future<void> sendChatMessage(String tradeId, String message) async {
    try {
      final request = SendChatMessageRequest()
        ..tradeId = tradeId
        ..message = message;
      await _tradesClient.sendChatMessage(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get a dispute by trade id.
  Future<Dispute> getDispute(String tradeId) async {
    try {
      return (await _disputesClient.getDispute(GetDisputeRequest()..tradeId = tradeId, options: _options)).dispute;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Get all disputes.
  Future<List<Dispute>> getDisputes() async {
    try {
      return (await _disputesClient.getDisputes(GetDisputesRequest(), options: _options)).disputes;
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Open a dispute for a trade.
  Future<void> openDispute(String tradeId) async {
    try {
      await _disputesClient.openDispute(OpenDisputeRequest()..tradeId = tradeId, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Resolve a dispute. By default, the winner receives the trade amount and the
  /// security deposits are returned, but the arbitrator may award a custom amount
  /// to the winner and the loser will get the rest.
  Future<void> resolveDispute(String tradeId, DisputeResult_Winner winner, DisputeResult_Reason reason,
      String summaryNotes, {BigInt? customWinnerAmount}) async {
    try {
      final request = ResolveDisputeRequest()
        ..tradeId = tradeId
        ..winner = winner
        ..reason = reason
        ..summaryNotes = summaryNotes
        ..customPayoutAmount = Int64.parseInt((customWinnerAmount ?? BigInt.zero).toString());
      await _disputesClient.resolveDispute(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Send a dispute chat message.
  Future<void> sendDisputeChatMessage(String disputeId, String message, List<Attachment> attachments) async {
    try {
      final request = SendDisputeChatMessageRequest()
        ..disputeId = disputeId
        ..message = message
        ..attachments.addAll(attachments);
      await _disputesClient.sendDisputeChatMessage(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Disconnect this client from the server.
  Future<void> disconnect() async {
    while (_notificationListeners.isNotEmpty) {
      await removeNotificationListener(_notificationListeners.first);
    }
  }

  /// Shutdown the Haveno daemon server and stop the process if applicable.
  Future<void> shutdownServer() async {
    try {
      await disconnect();
      await _shutdownServerClient.stop(StopRequest(), options: _options); // process receives 'exit' event
      if (_process != null) await HavenoUtils.kill(_process!);
    } catch (e) {
      HavenoUtils.log(0, 'Error gracefully shutting down havenod: $e');
      if (_process != null) {
        try {
          await HavenoUtils.kill(_process!);
        } catch (e2) {
          HavenoUtils.log(0, 'Error terminating havenod process: $e2. Stopping forcefully');
          await HavenoUtils.kill(_process!, ProcessSignal.sigkill);
        }
      }
    } finally {
      await _channel.shutdown();
    }
  }

  /// Close the underlying gRPC channel. The client cannot be used afterwards.
  ///
  /// This method is specific to the Dart port. Unlike haveno-ts there is no
  /// grpc-web stream to tear down, but the native gRPC channel holds a socket
  /// which keeps the Dart process alive until it is closed.
  Future<void> close() async {
    await _channel.shutdown();
  }

  // ------------------------------- HELPERS ----------------------------------

  /// Callback for grpc notifications.
  void _onNotification(NotificationMessage data) {
    for (final listener in List.of(_notificationListeners)) {
      listener(data);
    }
  }

  /// Update notification listener registration.
  ///
  /// Due to the nature of grpc streaming, this method returns a future
  /// which may be resolved before the listener is actually registered.
  Future<void> _updateNotificationListenerRegistration() async {
    try {
      final listening = _notificationListeners.isNotEmpty;
      if ((listening && _notificationStream != null) || (!listening && _notificationStream == null)) return; // no difference
      if (listening) {
        // send request to register client listener
        _notificationStream = _notificationsClient.registerNotificationListener(RegisterNotificationListenerRequest(), options: _options);
        _notificationSubscription = _notificationStream!.listen(_onNotification);

        // periodically send keep alive requests
        var firstRequest = true;
        _keepAliveLooper = TaskLooper(() async {
          if (firstRequest) {
            firstRequest = false;
            return;
          }
          try {
            await _sendNotification(NotificationMessage()
              ..type = NotificationMessage_NotificationType.KEEP_ALIVE
              ..timestamp = Int64(DateTime.now().millisecondsSinceEpoch));
          } catch (err) {
            HavenoUtils.log(0, 'Error sending keep alive request to Haveno daemon $_url: $err');
          }
        });
        _keepAliveLooper!.start(_keepAlivePeriodMs);
        await HavenoUtils.waitFor(1000); // TODO: call returns before listener registered
      } else {
        await _notificationSubscription?.cancel();
        _notificationSubscription = null;
        _notificationStream = null;
        _keepAliveLooper?.stop();
        _keepAliveLooper = null;
      }
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Send a notification.
  Future<void> _sendNotification(NotificationMessage notification) async {
    try {
      await _notificationsClient.sendNotification(SendNotificationRequest()..notification = notification, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }

  /// Restore an account chunk from zip bytes.
  Future<void> _restoreAccountChunk(Uint8List zipBytes, int offset, int totalLength, bool hasMore) async {
    try {
      final request = RestoreAccountRequest()
        ..zipBytes = zipBytes
        ..offset = Int64(offset)
        ..totalLength = Int64(totalLength)
        ..hasMore = hasMore;
      await _accountClient.restoreAccount(request, options: _options);
    } catch (e) {
      throw _toHavenoError(e);
    }
  }
}

/// Convert an error to a HavenoError.
HavenoError _toHavenoError(Object e) {
  if (e is HavenoError) return e;
  if (e is GrpcError) return HavenoError(e.message ?? 'gRPC error', e.code);
  return HavenoError(e.toString());
}
