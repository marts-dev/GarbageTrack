import 'package:flutter/foundation.dart';

import '../api/ai_api.dart';
import '../api/api_client.dart';
import '../api/auth_api.dart';
import '../api/garbage_api.dart';
import '../api/logistics_api.dart';
import '../api/truck_api.dart';
import '../api/user_api.dart';
import '../config.dart';
import '../models/models.dart';
import 'token_store.dart';

/// Session state: current user, tokens, and the authenticated API surface.
class AuthProvider extends ChangeNotifier {
  AuthProvider({ApiClient? client, TokenStore? tokenStore})
      : _store = tokenStore ?? TokenStore() {
    _initApis(client);
  }

  @visibleForTesting
  AuthProvider.withUser(this._user, {ApiClient? client, TokenStore? tokenStore})
      : _store = tokenStore ?? TokenStore() {
    _ready = true;
    _initApis(client);
  }

  void _initApis(ApiClient? client) {
    _client = client ??
        ApiClient(
          baseUrl: ApiConfig.baseUrl,
          readToken: () async => _tokens?.accessToken,
          refreshTokens: _refreshSilently,
        );
    auth = AuthApi(_client);
    users = UserApi(_client);
    garbage = GarbageApi(_client);
    trucks = TruckApi(_client);
    logistics = LogisticsApi(_client);
    ai = AiApi(_client);
  }

  final TokenStore _store;
  late final ApiClient _client;

  late final AuthApi auth;
  late final UserApi users;
  late final GarbageApi garbage;
  late final TruckApi trucks;
  late final LogisticsApi logistics;
  late final AiApi ai;

  User? _user;
  Tokens? _tokens;
  bool _busy = false;
  bool _ready = false;

  User? get user => _user;
  bool get isAuthenticated => _user != null;
  bool get isBusy => _busy;
  bool get isReady => _ready;

  Future<bool> _refreshSilently() async {
    final refresh = _tokens?.refreshToken;
    if (refresh == null) return false;
    try {
      _tokens = await auth.refresh(refresh);
      await _store.write(TokenStore.accessKey, _tokens!.accessToken);
      await _store.write(TokenStore.refreshKey, _tokens!.refreshToken);
      notifyListeners();
      return true;
    } on ApiException {
      return false;
    }
  }

  Future<void> _applySession(User user, Tokens tokens) async {
    _user = user;
    _tokens = tokens;
    await _store.write(TokenStore.accessKey, tokens.accessToken);
    await _store.write(TokenStore.refreshKey, tokens.refreshToken);
    notifyListeners();
  }

  /// Restores a previous session from stored tokens, if any.
  Future<void> tryAutoLogin() async {
    final refresh = await _store.read(TokenStore.refreshKey);
    if (refresh != null) {
      _tokens = Tokens(accessToken: '', refreshToken: refresh);
      if (await _refreshSilently()) {
        try {
          _user = await auth.me();
        } on ApiException {
          await logout();
        }
      } else {
        await logout();
      }
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> login({required String email, required String password}) async {
    _busy = true;
    notifyListeners();
    try {
      final tokens = await auth.login(email: email, password: password);
      _tokens = tokens;
      final user = await auth.me();
      await _applySession(user, tokens);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> register({
    required String email,
    required String password,
    String? fullName,
    String role = 'resident',
  }) async {
    _busy = true;
    notifyListeners();
    try {
      await auth.register(email: email, password: password, fullName: fullName, role: role);
      final tokens = await auth.login(email: email, password: password);
      _tokens = tokens;
      final user = await auth.me();
      await _applySession(user, tokens);
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    _user = null;
    _tokens = null;
    await _store.clear();
    notifyListeners();
  }

  Future<void> refreshUser() async {
    if (_user == null) return;
    _user = await auth.me();
    notifyListeners();
  }

  Future<void> updateProfile(String fullName) async {
    _user = await auth.updateProfile(fullName);
    notifyListeners();
  }
}
