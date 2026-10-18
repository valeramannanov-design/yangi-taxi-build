part of 'main.dart';

/// Android only. An unconfigured build never initializes Firebase or asks permission.
class GoAndroidPush {
  static final instance = GoAndroidPush();
  static const project = String.fromEnvironment('GO_FIREBASE_PROJECT_ID');
  static const _app = String.fromEnvironment('GO_FIREBASE_APP_ID');
  static const _sender = String.fromEnvironment('GO_FIREBASE_SENDER_ID');
  static const _key = String.fromEnvironment('GO_FIREBASE_API_KEY');
  bool get configured =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      [project, _app, _sender, _key].every((s) => s.isNotEmpty);
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  ApiClient? _api;
  String? _auth, _lang, _installation;
  int _epoch = 0;
  bool enabled = false;
  VoidCallback? _onChange, _onOpen;
  StreamSubscription<String>? _registered;
  StreamSubscription<RemoteMessage>? _messages, _opens;
  Map<String, dynamic>? _pending;
  String? _pendingKey;
  String get _preference => 'go-push-enabled:${_api?.baseUrl}';
  String get _deviceKey => 'go-push-installation:${_api?.baseUrl}';
  Future<void> _init() async {
    if (Firebase.apps.isEmpty)
      await Firebase.initializeApp(
          options: const FirebaseOptions(
              apiKey: _key,
              appId: _app,
              messagingSenderId: _sender,
              projectId: project));
  }

  void attach(ApiClient api, String lang,
      {required VoidCallback onChange, required VoidCallback onOpen}) {
    final unchanged = _api == api && _auth == api.token && _lang == lang;
    _api = api;
    _auth = api.token;
    _lang = lang;
    _onChange = onChange;
    _onOpen = onOpen;
    if (!configured || unchanged) return;
    final epoch = ++_epoch;
    unawaited(() async {
      try {
        if (await _storage.read(key: _preference) == '1' && epoch == _epoch)
          await enable(api, lang, ask: false);
      } catch (_) {/* Inbox/polling does not depend on FCM. */}
    }());
  }

  void detach(ApiClient api) {
    if (_api != api) return;
    _epoch++;
    _api = null;
    _onChange = null;
    _onOpen = null;
    unawaited(_registered?.cancel());
    unawaited(_messages?.cancel());
    unawaited(_opens?.cancel());
  }

  Future<void> enable(ApiClient api, String lang, {bool ask = true}) async {
    if (!configured) throw StateError('Android FCM is not configured');
    final auth = api.token, epoch = _epoch;
    final summary = await api.deliveryGet('/customer/notification-summary');
    if (summary['push']?['available'] != true ||
        summary['push']?['project_id'] != project)
      throw StateError('Server FCM is not configured for this app');
    await _init();
    final messaging = FirebaseMessaging.instance;
    final permission = ask
        ? await messaging.requestPermission()
        : await messaging.getNotificationSettings();
    if (permission.authorizationStatus != AuthorizationStatus.authorized)
      throw StateError('Android notification permission is not granted');
    _installation =
        await _storage.read(key: _deviceKey) ?? deliveryRequestKey();
    await _storage.write(key: _deviceKey, value: _installation);
    if (epoch != _epoch || api.token != auth) return;
    _api = api;
    _auth = auth;
    _lang = lang;
    await _registered?.cancel();
    await _messages?.cancel();
    await _opens?.cancel();
    _pending = null;
    _pendingKey = null;
    final registered = Completer<void>();
    _registered = messaging.onRegistered.listen((fid) {
      unawaited(() async {
        try {
          if (epoch != _epoch || api.token != auth) return;
          final payload = <String, dynamic>{
            'installation_id': _installation,
            'fid': fid,
            'lang': _lang
          };
          if (jsonEncode(payload) != jsonEncode(_pending)) {
            _pending = payload;
            _pendingKey = deliveryRequestKey();
          }
          await api.deliveryPost('/customer/push/register', _pending!,
              idempotencyKey: _pendingKey);
          if (epoch == _epoch && api.token == auth) {
            enabled = true;
            await _storage.write(key: _preference, value: '1');
            if (!registered.isCompleted) registered.complete();
          }
        } catch (_) {
          if (!registered.isCompleted)
            registered.completeError(StateError('Server registration failed'));
        }
      }());
    }, onError: (_) {
      if (!registered.isCompleted)
        registered.completeError(StateError('FCM registration failed'));
    });
    _messages = FirebaseMessaging.onMessage.listen((m) {
      if (epoch == _epoch &&
          api.token == auth &&
          m.data.containsKey('go_notice')) _onChange?.call();
    });
    _opens = FirebaseMessaging.onMessageOpenedApp.listen((m) {
      if (epoch == _epoch &&
          api.token == auth &&
          m.data.containsKey('go_notice')) _onOpen?.call();
    });
    final initial = await messaging.getInitialMessage();
    if (initial?.data.containsKey('go_notice') == true &&
        epoch == _epoch &&
        api.token == auth) _onOpen?.call();
    await messaging.setAutoInitEnabled(true);
    try {
      await Future.wait<void>([
        messaging.register(),
        registered.future.timeout(const Duration(seconds: 20))
      ]);
    } catch (_) {
      await messaging.setAutoInitEnabled(false);
      await messaging.unregister();
      rethrow;
    }
  }

  Future<void> disable(ApiClient api) async {
    if (_api != null && _api != api) return;
    _epoch++;
    enabled = false;
    _pending = null;
    _pendingKey = null;
    await _registered?.cancel();
    await _messages?.cancel();
    await _opens?.cancel();
    if (!configured) return;
    try {
      await _storage.delete(key: _preference);
      final id = _installation ?? await _storage.read(key: _deviceKey);
      if (id != null)
        await api.deliveryPost('/customer/push/revoke', {'installation_id': id},
            idempotencyKey: deliveryRequestKey());
    } finally {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseMessaging.instance.setAutoInitEnabled(false);
        await FirebaseMessaging.instance.unregister();
      }
    }
  }
}

class GoAndroidPushSetting extends StatefulWidget {
  const GoAndroidPushSetting(
      {super.key, required this.api, required this.lang});
  final ApiClient api;
  final String lang;
  @override
  State<GoAndroidPushSetting> createState() => _GoAndroidPushSettingState();
}

class _GoAndroidPushSettingState extends State<GoAndroidPushSetting> {
  bool _busy = false;
  String? _message;
  @override
  Widget build(BuildContext context) {
    final push = GoAndroidPush.instance, uz = widget.lang == 'uz';
    return ListTile(
        leading: const Icon(Icons.notifications_outlined),
        title: Text(uz ? 'Android push' : 'Push Android'),
        subtitle: Text(_message ??
            (!push.configured
                ? (uz ? 'Xizmat hali ulanmagan' : 'Сервис пока не подключён')
                : push.enabled
                    ? (uz ? 'Yoqilgan' : 'Включены')
                    : (uz ? 'O‘chirilgan' : 'Выключены'))),
        trailing: Switch(
            value: push.enabled,
            onChanged: _busy || !push.configured
                ? null
                : (value) async {
                    setState(() => _busy = true);
                    try {
                      if (value)
                        await push.enable(widget.api, widget.lang);
                      else
                        await push.disable(widget.api);
                      if (mounted) setState(() => _message = null);
                    } catch (_) {
                      if (mounted)
                        setState(() => _message = uz
                            ? 'Ulanish yoki ruxsatni tekshiring'
                            : 'Проверьте подключение сервиса и разрешение Android');
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  }));
  }
}
