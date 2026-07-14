import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/constants.dart';

/// Thin wrapper around Supabase client. All DB mutations go through
/// SECURITY DEFINER RPCs that verify `X-Identity-Id` + `X-Identity-Token`
/// headers (set on the underlying client via [setActiveIdentity]).
class SupabaseBackend {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Set the per-identity auth headers on the underlying client so all
  /// subsequent RPCs are authenticated.
  static void setActiveIdentity(String identityId, String authToken) {
    _client.headers['X-Identity-Id'] = identityId;
    _client.headers['X-Identity-Token'] = authToken;
  }

  static void clearActiveIdentity() {
    _client.headers.remove('X-Identity-Id');
    _client.headers.remove('X-Identity-Token');
  }

  // ---------- identity ----------

  static Future<({String id, String authToken, String displayCode})>
      registerIdentity(Uint8List publicKey) async {
    final res = await _client.rpc(
      'register_identity',
      params: {'p_public_key': base64Encode(publicKey)},
    );
    final row = (res as List).first as Map<String, dynamic>;
    return (
      id: row['id'] as String,
      authToken: row['auth_token'] as String,
      displayCode: row['display_code'] as String,
    );
  }

  // ---------- heartbeat ----------

  static Future<void> touchActive() async {
    await _client.rpc('touch_active');
  }

  // ---------- codes ----------

  static Future<String> createRotatingCode(String? alias) async {
    final res = await _client.rpc(
      'create_rotating_code',
      params: {'p_alias': alias},
    );
    return res as String;
  }

  static Future<({String identityId, Uint8List publicKey})> resolveCode(
      String code) async {
    final res = await _client.rpc(
      'resolve_code',
      params: {'p_code': code},
    );
    final row = (res as List).first as Map<String, dynamic>;
    return (
      identityId: row['identity_id'] as String,
      publicKey: Uint8List.fromList(base64Decode(row['public_key'] as String)),
    );
  }

  // ---------- friend requests ----------

  static Future<String> sendFriendRequest(String toIdentity, String? intro) async {
    final res = await _client.rpc(
      'send_friend_request',
      params: {'p_to_identity': toIdentity, 'p_intro': intro},
    );
    return res as String;
  }

  static Future<void> respondFriendRequest(String requestId, bool accept) async {
    await _client.rpc(
      'respond_friend_request',
      params: {'p_request_id': requestId, 'p_accept': accept},
    );
  }

  static Future<List<Map<String, dynamic>>> fetchFriendRequests() async {
    final res = await _client.rpc('fetch_friend_requests');
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<List<String>> listFriends() async {
    final res = await _client.rpc('list_friends');
    return (res as List).map((e) => (e as Map)['identity_id'] as String).toList();
  }

  static Future<Uint8List> fetchIdentityPublicKey(String identityId) async {
    final res = await _client.rpc(
      'fetch_identity_public_key',
      params: {'p_identity_id': identityId},
    );
    if (res is String) {
      if (res.startsWith(r'\x')) {
        final ascii = String.fromCharCodes(
          List<int>.generate((res.length - 2) ~/ 2, (i) {
            final hex = res.substring(2 + i * 2, 2 + i * 2 + 2);
            return int.parse(hex, radix: 16);
          }),
        );
        return base64Decode(ascii);
      }
      try {
        return base64Decode(res);
      } catch (_) {
        return Uint8List.fromList(
          List<int>.generate(res.length ~/ 2, (i) {
            return int.parse(res.substring(i * 2, i * 2 + 2), radix: 16);
          }),
        );
      }
    }
    if (res is Map && res['data'] is List) {
      return Uint8List.fromList(List<int>.from(res['data']));
    }
    if (res is List) {
      return Uint8List.fromList(List<int>.from(res));
    }
    throw StateError('unexpected public_key response: $res');
  }

  static Future<List<Map<String, dynamic>>> fetchOutgoingFriendRequests() async {
    final res = await _client.rpc('fetch_outgoing_friend_requests');
    return (res as List).cast<Map<String, dynamic>>();
  }

  // ---------- messages (1:1) ----------

  static Future<String> sendMessage({
    required String toIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    required String kind,
    String? attachmentPath,
    int? ttlSeconds,
  }) async {
    final res = await _client.rpc(
      'send_message',
      params: {
        'p_to_identity': toIdentity,
        'p_ciphertext': base64Encode(ciphertext),
        'p_iv': base64Encode(iv),
        'p_kind': kind,
        'p_attachment_path': attachmentPath,
        'p_ttl_seconds': ttlSeconds,
      },
    );
    return res as String;
  }

  static Future<void> markDelivered(String messageId) async {
    await _client.rpc('mark_delivered', params: {'p_message_id': messageId});
  }

  static Future<void> markRead(String messageId) async {
    await _client.rpc('mark_read', params: {'p_message_id': messageId});
  }

  static Future<void> deleteMessage(String messageId, bool forEveryone) async {
    await _client.rpc('delete_message', params: {
      'p_message_id': messageId,
      'p_for_everyone': forEveryone,
    });
  }

  static Future<List<Map<String, dynamic>>> fetchInbox(DateTime? since) async {
    final res = await _client.rpc(
      'fetch_inbox',
      params: {'p_since': since?.toUtc().toIso8601String()},
    );
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> fetchThread(
      String peerId, DateTime? since) async {
    final res = await _client.rpc(
      'fetch_thread',
      params: {
        'p_peer': peerId,
        'p_since': since?.toUtc().toIso8601String(),
      },
    );
    return (res as List).cast<Map<String, dynamic>>();
  }

  // ---------- privacy settings ----------

  static Future<({int disappearingSeconds, bool readReceipts})>
      getPrivacySettings() async {
    final res = await _client.rpc('get_privacy_settings');
    final row = (res as List).first as Map<String, dynamic>;
    return (
      disappearingSeconds: row['disappearing_seconds'] as int,
      readReceipts: row['read_receipts'] as bool,
    );
  }

  static Future<void> updateDisappearingDefault(int seconds) async {
    await _client.rpc('update_disappearing_default', params: {'p_seconds': seconds});
  }

  static Future<void> setReadReceiptsEnabled(bool enabled) async {
    await _client.rpc('set_read_receipts_enabled', params: {'p_enabled': enabled});
  }

  static Future<bool> peerReadReceiptsEnabled(String peerId) async {
    final res = await _client.rpc(
      'peer_read_receipts_enabled',
      params: {'p_peer': peerId},
    );
    return res as bool;
  }

  // ---------- aliases ----------

  static Future<void> setFriendAlias(String peerId, String? alias) async {
    await _client.rpc('set_friend_alias', params: {
      'p_peer': peerId,
      'p_alias': alias,
    });
  }

  static Future<Map<String, String?>> fetchFriendAliases() async {
    final res = await _client.rpc('fetch_friend_aliases');
    final out = <String, String?>{};
    for (final e in res as List) {
      final row = e as Map<String, dynamic>;
      out[row['peer_id'] as String] = row['alias'] as String?;
    }
    return out;
  }

  // ---------- group chats ----------

  static Future<String> createGroup(String name, List<String> memberIds) async {
    final res = await _client.rpc('create_group', params: {
      'p_name': name,
      'p_member_ids': memberIds,
    });
    return res as String;
  }

  static Future<List<Map<String, dynamic>>> listMyGroups() async {
    final res = await _client.rpc('list_my_groups');
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<List<Map<String, dynamic>>> listGroupMembers(
      String groupId) async {
    final res = await _client.rpc('list_group_members', params: {
      'p_group_id': groupId,
    });
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<String> sendGroupMessage({
    required String groupId,
    required List<String> recipients,
    required List<Uint8List> ciphertexts,
    required List<Uint8List> ivs,
    required String kind,
    String? attachmentPath,
    int? ttlSeconds,
  }) async {
    final res = await _client.rpc('send_group_message', params: {
      'p_group_id': groupId,
      'p_recipients': recipients,
      'p_ciphertexts': ciphertexts.map(base64Encode).toList(),
      'p_ivs': ivs.map(base64Encode).toList(),
      'p_kind': kind,
      'p_attachment_path': attachmentPath,
      'p_ttl_seconds': ttlSeconds,
    });
    return res as String;
  }

  static Future<List<Map<String, dynamic>>> fetchGroupInbox(DateTime? since) async {
    final res = await _client.rpc(
      'fetch_group_inbox',
      params: {'p_since': since?.toUtc().toIso8601String()},
    );
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<void> leaveGroup(String groupId) async {
    await _client.rpc('leave_group', params: {'p_group_id': groupId});
  }

  // ---------- onion routing ----------

  static Future<String> relaySend({
    required String toIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    String? finalKind,
    String? finalAttachmentPath,
  }) async {
    final res = await _client.rpc('relay_send', params: {
      'p_to_identity': toIdentity,
      'p_ciphertext': base64Encode(ciphertext),
      'p_iv': base64Encode(iv),
      'p_final_kind': finalKind,
      'p_final_attachment_path': finalAttachmentPath,
    });
    return res as String;
  }

  static Future<List<Map<String, dynamic>>> fetchRelayInbox(DateTime? since) async {
    final res = await _client.rpc(
      'fetch_relay_inbox',
      params: {'p_since': since?.toUtc().toIso8601String()},
    );
    return (res as List).cast<Map<String, dynamic>>();
  }

  static Future<String> relayDeliverFinal({
    required String toIdentity,
    required String fromIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    required String kind,
    String? attachmentPath,
  }) async {
    final res = await _client.rpc('relay_deliver_final', params: {
      'p_to_identity': toIdentity,
      'p_from_identity': fromIdentity,
      'p_ciphertext': base64Encode(ciphertext),
      'p_iv': base64Encode(iv),
      'p_kind': kind,
      'p_attachment_path': attachmentPath,
    });
    return res as String;
  }

  static Future<void> relayConsume(String hopId) async {
    await _client.rpc('relay_consume', params: {'p_hop_id': hopId});
  }

  // ---------- storage (attachments) ----------

  static Future<String> uploadAttachment({
    required String identityId,
    required String peerId,
    required Uint8List encryptedBytes,
    required String fileExt,
  }) async {
    final path =
        '${identityId}_${peerId}_${DateTime.now().millisecondsSinceEpoch}.$fileExt';
    await _client.storage.from(SupabaseConfig.storageBucket).uploadBinary(
          path,
          encryptedBytes,
          fileOptions: const FileOptions(
            contentType: 'application/octet-stream',
            upsert: false,
          ),
        );
    return path;
  }

  static Future<Uint8List> downloadAttachment(String path) async {
    return _client.storage.from(SupabaseConfig.storageBucket).download(path);
  }

  // ---------- Realtime subscriptions ----------

  static RealtimeChannel subscribeMessages({
    required String identityId,
    required void Function(Map<String, dynamic> row) onInsert,
  }) {
    return _client
        .channel('messages:$identityId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'to_identity',
            value: identityId,
          ),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  static RealtimeChannel subscribeGroupMessages({
    required String identityId,
    required void Function(Map<String, dynamic> row) onInsert,
  }) {
    return _client
        .channel('group_messages:$identityId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'group_messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'to_identity',
            value: identityId,
          ),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  static RealtimeChannel subscribeRelayHops({
    required String identityId,
    required void Function(Map<String, dynamic> row) onInsert,
  }) {
    return _client
        .channel('relay_hops:$identityId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'relay_hops',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'to_identity',
            value: identityId,
          ),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  static RealtimeChannel subscribeFriendRequests({
    required String identityId,
    required void Function(Map<String, dynamic> row) onInsert,
  }) {
    return _client
        .channel('friend_requests:$identityId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'friend_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'to_identity',
            value: identityId,
          ),
          callback: (payload) => onInsert(payload.newRecord),
        )
        .subscribe();
  }

  static RealtimeChannel subscribeFriendRequestUpdates({
    required String identityId,
    required void Function(Map<String, dynamic> row) onUpdate,
  }) {
    return _client
        .channel('friend_requests_update:$identityId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'friend_requests',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'from_identity',
            value: identityId,
          ),
          callback: (payload) => onUpdate(payload.newRecord),
        )
        .subscribe();
  }

  /// Subscribe to broadcast typing indicators on a per-peer channel.
  /// Both peers join the same channel (id = "typing:<sortedIds>").
  /// [onTyping] fires when the other peer broadcasts {'typing': true}.
  static RealtimeChannel subscribeTyping({
    required String myId,
    required String peerId,
    required void Function(bool typing) onTyping,
  }) {
    final ids = [myId, peerId]..sort();
    final chanId = 'typing:${ids[0]}.${ids[1]}';
    return _client.channel(chanId).onBroadcast(
      event: 'typing',
      callback: (payload) {
        final from = payload['from'] as String?;
        final t = payload['typing'] as bool?;
        if (from != null && from != myId && t != null) {
          onTyping(t);
        }
      },
    ).subscribe();
  }

  static void broadcastTyping({
    required String myId,
    required String peerId,
    required bool typing,
  }) {
    final ids = [myId, peerId]..sort();
    final chanId = 'typing:${ids[0]}.${ids[1]}';
    _client.channel(chanId).sendBroadcastMessage(
      event: 'typing',
      payload: {'from': myId, 'typing': typing},
    );
  }

  // ---------- direct REST helper ----------

  static Future<http.Response> postWithHeaders(
    String path,
    Map<String, dynamic> body,
    Map<String, String> headers,
  ) async {
    final uri = Uri.parse('${SupabaseConfig.url}$path');
    return http.post(
      uri,
      headers: {
        'apikey': SupabaseConfig.anonKey,
        'Content-Type': 'application/json',
        ...headers,
      },
      body: jsonEncode(body),
    );
  }
}
