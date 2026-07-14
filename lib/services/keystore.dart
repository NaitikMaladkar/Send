import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/identity.dart';
import '../models/friend.dart';

/// Encrypted on-device storage for identities + friends.
/// Uses flutter_secure_storage (Keystore on Android).
class SendKeystore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kIdentities = 'send.identities'; // JSON list
  static const _kActive = 'send.activeIdentity';
  static const _kFriendsPrefix = 'send.friends.'; // per-identity
  static const _kSharedKeyPrefix = 'send.shared.'; // per-(me,peer) cached ECDH key

  // ---------- identities (multi-account) ----------

  static Future<List<Identity>> loadIdentities() async {
    final raw = await _storage.read(key: _kIdentities);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Identity.fromJson(e as Map<String, dynamic>))
        .toList(growable: true);
  }

  static Future<void> saveIdentities(List<Identity> list) async {
    await _storage.write(
      key: _kIdentities,
      value: jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  static Future<String?> activeIdentityId() => _storage.read(key: _kActive);

  static Future<void> setActiveIdentity(String id) =>
      _storage.write(key: _kActive, value: id);

  static Future<void> clearActiveIdentity() =>
      _storage.delete(key: _kActive);

  // ---------- friends per identity ----------

  static Future<List<Friend>> loadFriends(String identityId) async {
    final raw = await _storage.read(key: _kFriendsPrefix + identityId);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Friend(
              identityId: e['identityId'] as String,
              publicKey: List<int>.from(e['publicKey'] as List),
              alias: e['alias'] as String?,
              friendedAt: DateTime.parse(e['friendedAt'] as String),
            ))
        .toList();
  }

  static Future<void> saveFriends(String identityId, List<Friend> list) async {
    await _storage.write(
      key: _kFriendsPrefix + identityId,
      value: jsonEncode(list
          .map((e) => {
                'identityId': e.identityId,
                'publicKey': e.publicKey,
                'alias': e.alias,
                'friendedAt': e.friendedAt.toIso8601String(),
              })
          .toList()),
    );
  }

  // ---------- cached shared symmetric keys ----------

  static Future<String?> sharedKey(String myId, String peerId) async {
    final k = _kSharedKeyPrefix + '$myId.$peerId';
    return _storage.read(key: k);
  }

  static Future<void> setSharedKey(String myId, String peerId, String hex) async {
    final k = _kSharedKeyPrefix + '$myId.$peerId';
    await _storage.write(key: k, value: hex);
  }

  // ---------- nuke everything (logout / delete identity) ----------

  static Future<void> wipeIdentity(String identityId) async {
    final all = await _storage.readAll();
    for (final entry in all.entries) {
      if (entry.key == _kFriendsPrefix + identityId ||
          entry.key.startsWith('$_kSharedKeyPrefix$identityId.') ||
          entry.key.startsWith('$_kSharedKeyPrefix.') && entry.key.endsWith('.$identityId')) {
        await _storage.delete(key: entry.key);
      }
    }
    final list = await loadIdentities();
    list.removeWhere((e) => e.id == identityId);
    await saveIdentities(list);
    final active = await activeIdentityId();
    if (active == identityId) await clearActiveIdentity();
  }
}
