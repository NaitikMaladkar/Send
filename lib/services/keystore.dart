import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/identity.dart';
import '../models/friend.dart';
import '../models/group.dart';

/// Encrypted on-device storage for identities + friends + groups.
/// Uses flutter_secure_storage (Keystore on Android).
class SendKeystore {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kIdentities = 'send.identities'; // JSON list
  static const _kActive = 'send.activeIdentity';
  static const _kFriendsPrefix = 'send.friends.'; // per-identity
  static const _kGroupsPrefix = 'send.groups.'; // per-identity
  static const _kSharedKeyPrefix = 'send.shared.'; // per-(me,peer) cached ECDH key
  static const _kGroupKeyPrefix = 'send.groupkey.'; // per-(me,group) cached group key
  static const _kPin = 'send.pin'; // 4-digit app PIN (device-only)
  static const _kPinSetAt = 'send.pin.setAt'; // ISO timestamp (for reset UX)

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
        .map((e) => Friend.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveFriends(String identityId, List<Friend> list) async {
    await _storage.write(
      key: _kFriendsPrefix + identityId,
      value: jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  // ---------- groups per identity ----------

  static Future<List<Group>> loadGroups(String identityId) async {
    final raw = await _storage.read(key: _kGroupsPrefix + identityId);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list
        .map((e) => Group.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveGroups(String identityId, List<Group> list) async {
    await _storage.write(
      key: _kGroupsPrefix + identityId,
      value: jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  // ---------- cached shared symmetric keys (1:1) ----------

  static Future<String?> sharedKey(String myId, String peerId) async {
    final k = _kSharedKeyPrefix + '$myId.$peerId';
    return _storage.read(key: k);
  }

  static Future<void> setSharedKey(String myId, String peerId, String hex) async {
    final k = _kSharedKeyPrefix + '$myId.$peerId';
    await _storage.write(key: k, value: hex);
  }

  // ---------- cached group symmetric keys ----------

  static Future<String?> groupKey(String myId, String groupId) async {
    final k = '$_kGroupKeyPrefix$myId.$groupId';
    return _storage.read(key: k);
  }

  static Future<void> setGroupKey(
      String myId, String groupId, String hex) async {
    final k = '$_kGroupKeyPrefix$myId.$groupId';
    await _storage.write(key: k, value: hex);
  }

  // ---------- PIN (device-only, 4-digit app lock) ----------

  /// Read the stored PIN. Returns null if no PIN has been set.
  static Future<String?> loadPin() => _storage.read(key: _kPin);

  static Future<bool> hasPin() async => (await _storage.read(key: _kPin)) != null;

  static Future<void> savePin(String pin) async {
    await _storage.write(key: _kPin, value: pin);
    await _storage.write(key: _kPinSetAt, value: DateTime.now().toIso8601String());
  }

  static Future<void> clearPin() async {
    await _storage.delete(key: _kPin);
    await _storage.delete(key: _kPinSetAt);
  }

  // ---------- nuke everything (logout / delete identity) ----------

  static Future<void> wipeIdentity(String identityId) async {
    final all = await _storage.readAll();
    for (final entry in all.entries) {
      if (entry.key == _kFriendsPrefix + identityId ||
          entry.key == _kGroupsPrefix + identityId ||
          entry.key.startsWith('$_kSharedKeyPrefix$identityId.') ||
          entry.key.startsWith('$_kGroupKeyPrefix$identityId.') ||
          entry.key.startsWith('$_kSharedKeyPrefix.') &&
              entry.key.endsWith('.$identityId')) {
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
