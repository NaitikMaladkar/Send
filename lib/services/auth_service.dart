import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/friend.dart';
import '../models/identity.dart';
import 'crypto.dart';
import 'keystore.dart';
import 'supabase_backend.dart';

/// Central app state: active identity, friends list, periodic heartbeat,
/// and the bridge between local secure storage + Supabase RPCs.
class AuthService extends ChangeNotifier {
  Identity? _active;
  List<Friend> _friends = [];
  Timer? _heartbeat;

  Identity? get active => _active;
  List<Friend> get friends => _friends;
  bool get hasIdentity => _active != null;

  /// Load saved identities from secure storage + restore active session.
  Future<void> init() async {
    final list = await SendKeystore.loadIdentities();
    if (list.isEmpty) return;
    final activeId = await SendKeystore.activeIdentityId();
    _active = list.firstWhere(
      (e) => e.id == activeId,
      orElse: () => list.first,
    );
    _friends = await SendKeystore.loadFriends(_active!.id);
    _applyHeaders();
    _startHeartbeat();
    notifyListeners();
  }

  /// Create a brand-new anonymous identity on this device.
  Future<Identity> createIdentity() async {
    final kp = await SendCrypto.generateKeyPair();
    final pub = await SendCrypto.exportPublic(kp);
    final priv = await SendCrypto.exportPrivate(kp);

    final reg = await SupabaseBackend.registerIdentity(pub);

    final id = Identity(
      id: reg.id,
      authToken: reg.authToken,
      displayCode: reg.displayCode,
      publicKey: pub,
      privateKey: priv,
    );

    final list = await SendKeystore.loadIdentities();
    list.add(id);
    await SendKeystore.saveIdentities(list);
    await SendKeystore.setActiveIdentity(id.id);

    _active = id;
    _friends = [];
    _applyHeaders();
    _startHeartbeat();
    notifyListeners();
    return id;
  }

  /// Switch to a different locally-stored identity (multi-account).
  Future<void> switchTo(String identityId) async {
    final list = await SendKeystore.loadIdentities();
    final found = list.firstWhere((e) => e.id == identityId);
    await SendKeystore.setActiveIdentity(identityId);
    _active = found;
    _friends = await SendKeystore.loadFriends(identityId);
    _applyHeaders();
    _startHeartbeat();
    notifyListeners();
  }

  /// Add a friend after an accepted request — caches their public key.
  Future<void> addFriend(Friend f) async {
    if (_active == null) return;
    _friends = [..._friends, f];
    await SendKeystore.saveFriends(_active!.id, _friends);
    notifyListeners();
  }

  /// Get a cached shared symmetric key (or derive + cache it).
  ///
  /// The HKDF info string MUST be SYMMETRIC in (myId, peerId) — i.e. both
  /// sides derive the same key. We lexically order the two ids and join them,
  /// so it doesn't matter who is "me" and who is "peer".
  Future<Uint8List> sharedKeyWith(String peerId, Uint8List peerPublicKey) async {
    if (_active == null) throw StateError('no active identity');
    final cached = await SendKeystore.sharedKey(_active!.id, peerId);
    if (cached != null) return hexDecode(cached);

    final kp = await SendCrypto.importPrivate(_active!.privateKey);
    // Symmetric info: order the two ids lexicographically.
    final ids = [_active!.id, peerId]..sort();
    final derived = await SendCrypto.deriveSharedKey(
      myPrivate: kp,
      theirPublic: peerPublicKey,
      info: 'send:v1:${ids[0]}.${ids[1]}',
    );
    await SendKeystore.setSharedKey(_active!.id, peerId, hexEncode(derived));
    return derived;
  }

  /// Find a cached friend by id.
  Friend? friend(String id) {
    for (final f in _friends) {
      if (f.identityId == id) return f;
    }
    return null;
  }

  /// Delete the active identity locally and from server.
  /// Server will drop the row via cleanup_inactive_identities within 24h
  /// (or immediately if we stop touching `last_active_at`).
  Future<void> deleteActive() async {
    if (_active == null) return;
    _heartbeat?.cancel();
    final deletedId = _active!.id;
    await SendKeystore.wipeIdentity(deletedId);
    _active = null;
    _friends = [];
    SupabaseBackend.clearActiveIdentity();
    // Try to restore another stored identity, if any.
    final list = await SendKeystore.loadIdentities();
    if (list.isNotEmpty) {
      await switchTo(list.first.id);
    } else {
      notifyListeners();
    }
  }

  void _applyHeaders() {
    if (_active != null) {
      SupabaseBackend.setActiveIdentity(_active!.id, _active!.authToken);
    } else {
      SupabaseBackend.clearActiveIdentity();
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    // Send a touch_active() every 5 minutes to keep last_active_at fresh.
    _heartbeat = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_active == null) return;
      SupabaseBackend.touchActive().catchError((_) {});
    });
    // Fire one immediately.
    if (_active != null) {
      SupabaseBackend.touchActive().catchError((_) {});
    }
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    super.dispose();
  }
}

String hexEncode(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexDecode(String s) {
  if (s.length.isOdd) s = '0$s';
  final out = <int>[];
  for (var i = 0; i < s.length; i += 2) {
    out.add(int.parse(s.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(out);
}
