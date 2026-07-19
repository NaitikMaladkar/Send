import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/constants.dart';

/// Thin wrapper around Supabase. All DB mutations go through SECURITY DEFINER
/// RPCs that verify `X-Identity-Id` + `X-Identity-Token` headers.
///
/// NOTE: supabase_flutter 2.x exposes `client.headers` as an **unmodifiable**
/// map, so we cannot mutate it after init. Instead, we route all RPC + storage
/// calls through direct HTTP via the PostgREST / Storage REST endpoints,
/// attaching the identity headers per call. Realtime subscriptions are kept on
/// the Supabase client (with per-channel headers via RealtimeChannelOptions).
class SupabaseBackend {
  static SupabaseClient get _client => Supabase.instance.client;

  // ---------- per-identity auth state (in-memory) ----------

  static String? _identityId;
  static String? _authToken;

  /// Set the per-identity auth headers used by all subsequent RPC + storage
  /// calls. Stored in static fields because supabase_flutter 2.x's headers
  /// map is unmodifiable.
  static void setActiveIdentity(String identityId, String authToken) {
    _identityId = identityId;
    _authToken = authToken;
  }

  static void clearActiveIdentity() {
    _identityId = null;
    _authToken = null;
  }

  /// Common headers attached to every direct-HTTP call.
  static Map<String, String> get _commonHeaders => {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        'Content-Type': 'application/json',
        if (_identityId != null) 'X-Identity-Id': _identityId!,
        if (_authToken != null) 'X-Identity-Token': _authToken!,
      };

  // NOTE: supabase_flutter 2.13.x's RealtimeChannelConfig does NOT support
  // per-channel headers, so we cannot attach X-Identity-Id to the websocket
  // subscription. RLS policies that check `request.header.x-identity-id`
  // will therefore block row delivery over Realtime for our use case.
  // To compensate, callers rely on short-interval polling (3–5s) of the
  // fetch_inbox / fetch_thread / fetch_group_inbox / fetch_relay_inbox RPCs
  // — which DO go through direct HTTP with identity headers attached.
  // Realtime broadcast channels (used for typing indicators) work fine
  // because broadcast does not pass through RLS.

  // ---------- low-level HTTP helpers ----------

  /// Invoke a PostgREST RPC function via direct HTTP, attaching identity
  /// headers. Returns the parsed JSON body.
  static Future<dynamic> _rpc(
    String functionName, [
    Map<String, dynamic>? params,
  ]) async {
    final uri = Uri.parse('${SupabaseConfig.url}/rest/v1/rpc/$functionName');
    final res = await http.post(
      uri,
      headers: _commonHeaders,
      body: params == null ? '{}' : jsonEncode(params),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
          'RPC $functionName failed: ${res.statusCode} ${res.body}');
    }
    if (res.body.isEmpty) return null;
    return jsonDecode(res.body);
  }

  // ---------- identity ----------

  static Future<({String id, String authToken, String displayCode})>
      registerIdentity(Uint8List publicKey) async {
    final res = await _rpc('register_identity', {
      'p_public_key': base64Encode(publicKey),
    });
    final row = (res as List).first as Map<String, dynamic>;
    return (
      id: row['id'] as String,
      authToken: row['auth_token'] as String,
      displayCode: row['display_code'] as String,
    );
  }

  // ---------- heartbeat ----------

  static Future<void> touchActive() async {
    await _rpc('touch_active');
  }

  // ---------- codes ----------

  static Future<String> createRotatingCode(String? alias) async {
    final res = await _rpc('create_rotating_code', {'p_alias': alias});
    return res as String;
  }

  static Future<({String identityId, Uint8List publicKey})> resolveCode(
      String code) async {
    final res = await _rpc('resolve_code', {'p_code': code});
    final row = (res as List).first as Map<String, dynamic>;
    return (
      identityId: row['identity_id'] as String,
      publicKey: parseBytea(row['public_key']),
    );
  }

  /// Parse a bytea value returned by PostgREST.
  ///
  /// PostgREST returns bytea columns as `\x<hex>` strings where `<hex>` is
  /// the hex of the stored bytes. Because we send bytea RPC params as
  /// base64-encoded strings (e.g. `base64Encode(pubKey)`), Postgres stores
  /// the UTF-8 bytes of that base64 string, NOT the raw bytes. So to
  /// recover the original raw bytes we need to:
  ///   1. Strip the `\x` prefix
  ///   2. Hex-decode to get the UTF-8 bytes
  ///   3. Convert those bytes to a string (the base64 string we sent)
  ///   4. Base64-decode that string to get the original raw bytes
  ///
  /// If the bytea was generated server-side (e.g. by `gen_random_bytes`),
  /// step 4 will fail (it's not a valid base64 string) and we fall back to
  /// returning the raw bytes directly.
  static Uint8List parseBytea(dynamic v) {
    if (v == null) return Uint8List(0);
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(List<int>.from(v));
    if (v is String) {
      if (v.startsWith(r'\x')) {
        final hex = v.substring(2);
        final utf8Bytes = Uint8List.fromList(
          List<int>.generate(hex.length ~/ 2, (i) {
            return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
          }),
        );
        // utf8Bytes is the UTF-8 of the base64 string we sent.
        try {
          final b64 = String.fromCharCodes(utf8Bytes);
          return base64Decode(b64);
        } catch (_) {
          return utf8Bytes; // server-generated random bytes
        }
      }
      // Try direct base64 first.
      try {
        return base64Decode(v);
      } catch (_) {
        // Fall back to plain hex.
        return Uint8List.fromList(
          List<int>.generate(v.length ~/ 2, (i) {
            return int.parse(v.substring(i * 2, i * 2 + 2), radix: 16);
          }),
        );
      }
    }
    if (v is Map && v['data'] is List) {
      return Uint8List.fromList(List<int>.from(v['data']));
    }
    throw StateError('cannot parse bytea: $v (${v.runtimeType})');
  }

  // ---------- friend requests ----------

  static Future<String> sendFriendRequest(
      String toIdentity, String? intro) async {
    final res = await _rpc('send_friend_request', {
      'p_to_identity': toIdentity,
      'p_intro': intro,
    });
    return res as String;
  }

  static Future<void> respondFriendRequest(
      String requestId, bool accept) async {
    await _rpc('respond_friend_request', {
      'p_request_id': requestId,
      'p_accept': accept,
    });
  }

  static Future<List<Map<String, dynamic>>> fetchFriendRequests() async {
    final res = await _rpc('fetch_friend_requests');
    return _castRows(res);
  }

  static Future<List<String>> listFriends() async {
    final res = await _rpc('list_friends');
    return (res as List)
        .map((e) => (e as Map)['identity_id'] as String)
        .toList();
  }

  static Future<Uint8List> fetchIdentityPublicKey(String identityId) async {
    final res = await _rpc('fetch_identity_public_key', {
      'p_identity_id': identityId,
    });
    return parseBytea(res);
  }

  static Future<List<Map<String, dynamic>>>
      fetchOutgoingFriendRequests() async {
    final res = await _rpc('fetch_outgoing_friend_requests');
    return _castRows(res);
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
    final res = await _rpc('send_message', {
      'p_to_identity': toIdentity,
      'p_ciphertext': base64Encode(ciphertext),
      'p_iv': base64Encode(iv),
      'p_kind': kind,
      'p_attachment_path': attachmentPath,
      'p_ttl_seconds': ttlSeconds,
    });
    return res as String;
  }

  static Future<void> markDelivered(String messageId) async {
    await _rpc('mark_delivered', {'p_message_id': messageId});
  }

  static Future<void> markRead(String messageId) async {
    await _rpc('mark_read', {'p_message_id': messageId});
  }

  static Future<void> deleteMessage(
      String messageId, bool forEveryone) async {
    await _rpc('delete_message', {
      'p_message_id': messageId,
      'p_for_everyone': forEveryone,
    });
  }

  static Future<List<Map<String, dynamic>>> fetchInbox(DateTime? since) async {
    final res = await _rpc('fetch_inbox', {
      'p_since': since?.toUtc().toIso8601String(),
    });
    return _castRows(res);
  }

  static Future<List<Map<String, dynamic>>> fetchThread(
      String peerId, DateTime? since) async {
    final res = await _rpc('fetch_thread', {
      'p_peer': peerId,
      'p_since': since?.toUtc().toIso8601String(),
    });
    return _castRows(res);
  }

  // ---------- privacy settings ----------

  static Future<({int disappearingSeconds, bool readReceipts})>
      getPrivacySettings() async {
    final res = await _rpc('get_privacy_settings');
    final row = (res as List).first as Map<String, dynamic>;
    return (
      disappearingSeconds: row['disappearing_seconds'] as int,
      readReceipts: row['read_receipts'] as bool,
    );
  }

  static Future<void> updateDisappearingDefault(int seconds) async {
    await _rpc('update_disappearing_default', {'p_seconds': seconds});
  }

  static Future<void> setReadReceiptsEnabled(bool enabled) async {
    await _rpc('set_read_receipts_enabled', {'p_enabled': enabled});
  }

  static Future<bool> peerReadReceiptsEnabled(String peerId) async {
    final res = await _rpc('peer_read_receipts_enabled', {'p_peer': peerId});
    return res as bool;
  }

  // ---------- aliases ----------

  static Future<void> setFriendAlias(String peerId, String? alias) async {
    await _rpc('set_friend_alias', {
      'p_peer': peerId,
      'p_alias': alias,
    });
  }

  static Future<Map<String, String?>> fetchFriendAliases() async {
    final res = await _rpc('fetch_friend_aliases');
    final out = <String, String?>{};
    for (final e in res as List) {
      final row = e as Map<String, dynamic>;
      out[row['peer_id'] as String] = row['alias'] as String?;
    }
    return out;
  }

  // ---------- group chats ----------

  static Future<String> createGroup(
      String name, List<String> memberIds) async {
    final res = await _rpc('create_group', {
      'p_name': name,
      'p_member_ids': memberIds,
    });
    return res as String;
  }

  static Future<List<Map<String, dynamic>>> listMyGroups() async {
    final res = await _rpc('list_my_groups');
    return _castRows(res);
  }

  static Future<List<Map<String, dynamic>>> listGroupMembers(
      String groupId) async {
    final res = await _rpc('list_group_members', {'p_group_id': groupId});
    return _castRows(res);
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
    final res = await _rpc('send_group_message', {
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

  static Future<List<Map<String, dynamic>>> fetchGroupInbox(
      DateTime? since) async {
    final res = await _rpc('fetch_group_inbox', {
      'p_since': since?.toUtc().toIso8601String(),
    });
    return _castRows(res);
  }

  static Future<void> leaveGroup(String groupId) async {
    await _rpc('leave_group', {'p_group_id': groupId});
  }

  // ---------- onion routing ----------

  static Future<String> relaySend({
    required String toIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    String? finalKind,
    String? finalAttachmentPath,
  }) async {
    final res = await _rpc('relay_send', {
      'p_to_identity': toIdentity,
      'p_ciphertext': base64Encode(ciphertext),
      'p_iv': base64Encode(iv),
      'p_final_kind': finalKind,
      'p_final_attachment_path': finalAttachmentPath,
    });
    return res as String;
  }

  static Future<List<Map<String, dynamic>>> fetchRelayInbox(
      DateTime? since) async {
    final res = await _rpc('fetch_relay_inbox', {
      'p_since': since?.toUtc().toIso8601String(),
    });
    return _castRows(res);
  }

  static Future<String> relayDeliverFinal({
    required String toIdentity,
    required String fromIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    required String kind,
    String? attachmentPath,
  }) async {
    final res = await _rpc('relay_deliver_final', {
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
    await _rpc('relay_consume', {'p_hop_id': hopId});
  }

  // ---------- storage (attachments) ----------

  /// Upload an encrypted attachment via direct HTTP to the Storage REST API.
  /// Identity headers are attached so the storage RLS policy can authorize
  /// the upload.
  static Future<String> uploadAttachment({
    required String identityId,
    required String peerId,
    required Uint8List encryptedBytes,
    required String fileExt,
  }) async {
    final path =
        '${identityId}_${peerId}_${DateTime.now().millisecondsSinceEpoch}.$fileExt';
    final uri = Uri.parse(
        '${SupabaseConfig.url}/storage/v1/object/${SupabaseConfig.storageBucket}/$path');
    final res = await http.post(
      uri,
      headers: {
        'apikey': SupabaseConfig.anonKey,
        'Authorization': 'Bearer ${SupabaseConfig.anonKey}',
        'Content-Type': 'application/octet-stream',
        'x-upsert': 'false',
        if (_identityId != null) 'X-Identity-Id': _identityId!,
        if (_authToken != null) 'X-Identity-Token': _authToken!,
      },
      body: encryptedBytes,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
          'Storage upload failed: ${res.statusCode} ${res.body}');
    }
    return path;
  }

  /// Download an encrypted attachment via direct HTTP.
  static Future<Uint8List> downloadAttachment(String path) async {
    final uri = Uri.parse(
        '${SupabaseConfig.url}/storage/v1/object/${SupabaseConfig.storageBucket}/$path');
    final res = await http.get(uri, headers: _commonHeaders);
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
          'Storage download failed: ${res.statusCode} ${res.body}');
    }
    return res.bodyBytes;
  }

  // ---------- Realtime subscriptions ----------

  // All Realtime postgres_changes subscriptions below are kept as best-effort
  // delivery channels — they MAY be filtered out by RLS because we cannot
  // attach the X-Identity-Id header to the websocket subscription in
  // supabase_flutter 2.13.x. The polling in chats_tab / chat_screen /
  // group_chat_screen is the authoritative delivery path.

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
          callback: (payload) => onInsert(
              Map<String, dynamic>.from(payload.newRecord)),
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
          callback: (payload) => onInsert(
              Map<String, dynamic>.from(payload.newRecord)),
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
          callback: (payload) => onInsert(
              Map<String, dynamic>.from(payload.newRecord)),
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
          callback: (payload) => onInsert(
              Map<String, dynamic>.from(payload.newRecord)),
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
          callback: (payload) => onUpdate(
              Map<String, dynamic>.from(payload.newRecord)),
        )
        .subscribe();
  }

  /// Subscribe to broadcast typing indicators on a per-peer channel.
  /// Both peers join the same channel (id = "typing:<sortedIds>").
  /// [onTyping] fires when the other peer broadcasts {'typing': true}.
  /// Broadcast channels do not pass through RLS, so this works without
  /// identity headers.
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

  // ---------- helpers ----------

  /// Cast a PostgREST RPC result (which is a JSON List) into a
  /// List<Map<String, dynamic>>. Each row returned by PostgREST is a JSON
  /// object; we wrap it in `Map<String, dynamic>.from(...)` so callers can
  /// safely mutate / index it (the default Map view from jsonDecode is
  /// actually modifiable, but copying is safer and avoids surprises).
  static List<Map<String, dynamic>> _castRows(dynamic res) {
    if (res == null) return const [];
    if (res is! List) return const [];
    return res
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: true);
  }

  // ---------- direct REST helper (kept for backwards compat) ----------

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
