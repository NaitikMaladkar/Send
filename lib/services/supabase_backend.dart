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

  /// Register a new anonymous identity. Returns (id, authToken, displayCode).
  static Future<({String id, String authToken, String displayCode})> registerIdentity(
      Uint8List publicKey) async {
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

  // ---------- codes (rotating shareable link) ----------

  /// Create a fresh 24-hour rotating code (the "MyLink").
  static Future<String> createRotatingCode(String? alias) async {
    final res = await _client.rpc(
      'create_rotating_code',
      params: {'p_alias': alias},
    );
    return res as String;
  }

  /// Resolve someone else's code → their identity id + public key.
  static Future<({String identityId, Uint8List publicKey})> resolveCode(String code) async {
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

  static Future<String> sendFriendRequest(
    String toIdentity,
    String? intro,
  ) async {
    final res = await _client.rpc(
      'send_friend_request',
      params: {'p_to_identity': toIdentity, 'p_intro': intro},
    );
    return res as String;
  }

  static Future<void> respondFriendRequest(
    String requestId,
    bool accept,
  ) async {
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

  // ---------- messages ----------

  /// Send an encrypted message. `ciphertext` is AES-256-GCM output (with tag appended).
  static Future<String> sendMessage({
    required String toIdentity,
    required Uint8List ciphertext,
    required Uint8List iv,
    required String kind,
    String? attachmentPath,
  }) async {
    final res = await _client.rpc(
      'send_message',
      params: {
        'p_to_identity': toIdentity,
        'p_ciphertext': base64Encode(ciphertext),
        'p_iv': base64Encode(iv),
        'p_kind': kind,
        'p_attachment_path': attachmentPath,
      },
    );
    return res as String;
  }

  static Future<void> markDelivered(String messageId) async {
    await _client.rpc(
      'mark_delivered',
      params: {'p_message_id': messageId},
    );
  }

  static Future<void> markRead(String messageId) async {
    await _client.rpc(
      'mark_read',
      params: {'p_message_id': messageId},
    );
  }

  static Future<List<Map<String, dynamic>>> fetchInbox(DateTime? since) async {
    final res = await _client.rpc(
      'fetch_inbox',
      params: {'p_since': since?.toUtc().toIso8601String()},
    );
    return (res as List).cast<Map<String, dynamic>>();
  }

  // ---------- storage (attachments) ----------

  /// Upload an encrypted blob to the private `attachments` bucket.
  /// Returns the storage path that can be attached to a message.
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

  /// Download an attachment's bytes.
  static Future<Uint8List> downloadAttachment(String path) async {
    return _client.storage.from(SupabaseConfig.storageBucket).download(path);
  }

  // ---------- Realtime subscriptions ----------
  //
  // NOTE: Supabase Realtime respects RLS. Because we set `using(false)` on
  // every table (clients can't SELECT), Realtime INSERT events won't be
  // delivered. We still subscribe in case RLS is later relaxed; the polling
  // fallback in ChatService guarantees delivery for v1.

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

  // ---------- direct REST helper (for edge functions / uploads needing custom headers) ----------

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
