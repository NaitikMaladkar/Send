import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../models/friend.dart';
import '../models/group.dart';
import '../models/identity.dart';
import 'crypto.dart';
import 'keystore.dart';
import 'supabase_backend.dart';

/// Central app state: active identity, friends list, groups, periodic
/// heartbeat, and the bridge between local secure storage + Supabase RPCs.
class AuthService extends ChangeNotifier {
  Identity? _active;
  List<Friend> _friends = [];
  List<Group> _groups = [];
  Timer? _heartbeat;

  /// Per-identity privacy settings. Disappearing is fixed at 24h.
  bool _readReceipts = true;

  /// In-session PIN unlock flag. Reset on every cold start.
  bool _pinUnlocked = false;

  Identity? get active => _active;
  List<Friend> get friends => _friends;
  List<Group> get groups => _groups;
  bool get hasIdentity => _active != null;
  bool get readReceipts => _readReceipts;
  bool get pinUnlocked => _pinUnlocked;

  /// Mark PIN as unlocked for this session. Reset by re-launching the app.
  void markPinUnlocked() {
    _pinUnlocked = true;
    notifyListeners();
  }

  /// Load saved identities from secure storage + restore active session.
  /// Does NOT verify PIN — caller (splash_screen) handles PIN gating.
  Future<void> init() async {
    final list = await SendKeystore.loadIdentities();
    if (list.isEmpty) return;
    final activeId = await SendKeystore.activeIdentityId();
    _active = list.firstWhere(
      (e) => e.id == activeId,
      orElse: () => list.first,
    );
    _friends = await SendKeystore.loadFriends(_active!.id);
    _groups = await SendKeystore.loadGroups(_active!.id);
    _applyHeaders();
    _startHeartbeat();
    // Pull latest aliases + privacy settings from server (best-effort).
    await _syncFromServer();
    notifyListeners();
  }

  Future<void> _syncFromServer() async {
    if (_active == null) return;
    try {
      _readReceipts = await SupabaseBackend.getPrivacySettings();
    } catch (_) {}
    try {
      final aliases = await SupabaseBackend.fetchFriendAliases();
      var changed = false;
      _friends = _friends.map((f) {
        final a = aliases[f.identityId];
        if (a != f.alias) {
          changed = true;
          return f.copyWith(alias: a);
        }
        return f;
      }).toList();
      if (changed) {
        await SendKeystore.saveFriends(_active!.id, _friends);
      }
    } catch (_) {}
    try {
      final rows = await SupabaseBackend.listMyGroups();
      final newGroups = <Group>[];
      for (final row in rows) {
        final gid = row['group_id'] as String;
        try {
          final memberRows = await SupabaseBackend.listGroupMembers(gid);
          final memberIds =
              memberRows.map((m) => m['identity_id'] as String).toList();
          newGroups.add(Group(
            id: gid,
            name: row['name'] as String,
            createdBy: row['created_by'] as String,
            createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
            memberIds: memberIds,
          ));
        } catch (_) {}
      }
      _groups = newGroups;
      await SendKeystore.saveGroups(_active!.id, _groups);
    } catch (_) {}
  }

  /// Sign up: generate X25519 keypair, encrypt private key with the passkey,
  /// upload to server. The server returns the assigned public_id + auth_token.
  Future<Identity> signUp({
    required String displayName,
    required String passkey,
  }) async {
    final kp = await SendCrypto.generateKeyPair();
    final pub = await SendCrypto.exportPublic(kp);
    final priv = await SendCrypto.exportPrivate(kp);
    final salt = await SendCrypto.generatePasskeySalt();
    final encPriv = await SendCrypto.encryptPrivateKey(
      privateKey: priv,
      passkey: passkey,
      salt: salt,
    );

    final reg = await SupabaseBackend.signup(
      displayName: displayName,
      passkey: passkey,
      publicKey: pub,
      encryptedPrivateKey: encPriv,
      passkeySalt: salt,
    );

    final id = Identity(
      id: reg.id,
      authToken: reg.authToken,
      publicId: reg.publicId,
      displayName: reg.displayName,
      publicKey: pub,
      privateKey: priv,
      passkeySalt: salt,
    );

    final list = await SendKeystore.loadIdentities();
    // Remove any stale local identity with the same id (defensive)
    list.removeWhere((e) => e.id == id.id);
    list.add(id);
    await SendKeystore.saveIdentities(list);
    await SendKeystore.setActiveIdentity(id.id);

    _active = id;
    _friends = [];
    _groups = [];
    _readReceipts = true;
    _applyHeaders();
    _startHeartbeat();
    notifyListeners();
    return id;
  }

  /// Sign in with public_id + passkey. Server returns the encrypted private
  /// key blob; we decrypt it locally with the passkey.
  Future<Identity> signIn({required int publicId, required String passkey}) async {
    final res = await SupabaseBackend.signin(publicId: publicId, passkey: passkey);
    final priv = await SendCrypto.decryptPrivateKey(
      blob: res.encryptedPrivateKey,
      passkey: passkey,
    );

    final id = Identity(
      id: res.id,
      authToken: res.authToken,
      publicId: publicId,
      displayName: res.displayName,
      publicKey: res.publicKey,
      privateKey: priv,
      passkeySalt: res.passkeySalt,
    );

    final list = await SendKeystore.loadIdentities();
    list.removeWhere((e) => e.id == id.id);
    list.add(id);
    await SendKeystore.saveIdentities(list);
    await SendKeystore.setActiveIdentity(id.id);

    _active = id;
    _friends = [];
    _groups = [];
    _readReceipts = true;
    _applyHeaders();
    _startHeartbeat();
    await _syncFromServer();
    notifyListeners();
    return id;
  }

  /// Switch to a different locally-stored identity.
  Future<void> switchTo(String identityId) async {
    final list = await SendKeystore.loadIdentities();
    final found = list.firstWhere((e) => e.id == identityId);
    await SendKeystore.setActiveIdentity(identityId);
    _active = found;
    _friends = await SendKeystore.loadFriends(identityId);
    _groups = await SendKeystore.loadGroups(identityId);
    _applyHeaders();
    _startHeartbeat();
    await _syncFromServer();
    notifyListeners();
  }

  /// Add a friend after an accepted request — caches their public key.
  Future<void> addFriend(Friend f) async {
    if (_active == null) return;
    // de-dup by identityId
    final existing = _friends.indexWhere((e) => e.identityId == f.identityId);
    if (existing >= 0) {
      _friends[existing] = f;
    } else {
      _friends = [..._friends, f];
    }
    await SendKeystore.saveFriends(_active!.id, _friends);
    notifyListeners();
  }

  /// Update an existing friend's alias / TTL / onion preference.
  Future<void> updateFriend(Friend updated) async {
    if (_active == null) return;
    final i = _friends.indexWhere((f) => f.identityId == updated.identityId);
    if (i < 0) return;
    _friends[i] = updated;
    await SendKeystore.saveFriends(_active!.id, _friends);
    // Push alias to server so it syncs across devices.
    try {
      await SupabaseBackend.setFriendAlias(updated.identityId, updated.alias);
    } catch (_) {}
    notifyListeners();
  }

  Future<void> addGroup(Group g) async {
    if (_active == null) return;
    final i = _groups.indexWhere((e) => e.id == g.id);
    if (i >= 0) {
      _groups[i] = g;
    } else {
      _groups = [..._groups, g];
    }
    await SendKeystore.saveGroups(_active!.id, _groups);
    notifyListeners();
  }

  Future<void> refreshGroups() async {
    await _syncFromServer();
    notifyListeners();
  }

  Future<void> setReadReceipts(bool enabled) async {
    _readReceipts = enabled;
    try {
      await SupabaseBackend.setReadReceiptsEnabled(enabled);
    } catch (_) {}
    notifyListeners();
  }

  /// Get a cached shared symmetric key (or derive + cache it).
  ///
  /// The HKDF info string MUST be SYMMETRIC in (myId, peerId) — i.e. both
  /// sides derive the same key. We lexically order the two ids and join them,
  /// so it doesn't matter who is "me" and who is "peer".
  Future<Uint8List> sharedKeyWith(
      String peerId, Uint8List peerPublicKey) async {
    if (_active == null) throw StateError('no active identity');
    final cached = await SendKeystore.sharedKey(_active!.id, peerId);
    if (cached != null) return hexDecode(cached);

    final kp = await SendCrypto.importPrivate(_active!.privateKey);
    final ids = [_active!.id, peerId]..sort();
    final derived = await SendCrypto.deriveSharedKey(
      myPrivate: kp,
      theirPublic: peerPublicKey,
      info: 'send:v1:${ids[0]}.${ids[1]}',
    );
    await SendKeystore.setSharedKey(_active!.id, peerId, hexEncode(derived));
    return derived;
  }

  /// Derive (or load cached) per-(me, group) symmetric key.
  Future<Uint8List> groupKey(String groupId, String creatorId) async {
    if (_active == null) throw StateError('no active identity');
    final cached = await SendKeystore.groupKey(_active!.id, groupId);
    if (cached != null) return hexDecode(cached);

    final creator = _friends.firstWhere(
      (f) => f.identityId == creatorId,
      orElse: () => throw StateError('creator $creatorId not in friends'),
    );
    final kp = await SendCrypto.importPrivate(_active!.privateKey);
    final derived = await SendCrypto.deriveSharedKey(
      myPrivate: kp,
      theirPublic: Uint8List.fromList(creator.publicKey),
      info: 'send:group:$groupId',
    );
    await SendKeystore.setGroupKey(_active!.id, groupId, hexEncode(derived));
    return derived;
  }

  /// Find a cached friend by id.
  Friend? friend(String id) {
    for (final f in _friends) {
      if (f.identityId == id) return f;
    }
    return null;
  }

  /// Find a group by id.
  Group? group(String id) {
    for (final g in _groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// Bilateral account vanish: wipes everything from server AND local device.
  ///
  /// Server-side `vanish_account()` deletes:
  ///   - messages I sent OR received (both sides)
  ///   - group messages I sent OR received
  ///   - group memberships
  ///   - friend_requests (their list loses me too)
  ///   - friend_aliases (their alias for me is gone)
  ///   - hidden-message markers
  ///   - rotating codes
  ///   - relay hops
  ///   - the identity row itself (auth_token becomes invalid)
  ///
  /// Then we wipe local secure storage for this identity and clear PIN.
  Future<void> vanishAccount() async {
    if (_active == null) return;
    _heartbeat?.cancel();
    final deletedId = _active!.id;
    try {
      await SupabaseBackend.vanishAccount();
    } catch (_) {
      // Even if the server call fails (network issue, expired token, etc.),
      // we still wipe local state so the user is logged out.
    }
    await SendKeystore.wipeIdentity(deletedId);
    // Also clear the PIN — device is now unowned.
    await SendKeystore.clearPin();
    _active = null;
    _friends = [];
    _groups = [];
    _pinUnlocked = false;
    SupabaseBackend.clearActiveIdentity();
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
    _heartbeat = Timer.periodic(const Duration(minutes: 5), (_) {
      if (_active == null) return;
      SupabaseBackend.touchActive().catchError((_) {});
    });
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
