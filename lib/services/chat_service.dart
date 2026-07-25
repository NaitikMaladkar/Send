import 'dart:convert';
import 'dart:typed_data';

import '../models/message.dart';
import 'auth_service.dart';
import 'crypto.dart';
import 'supabase_backend.dart';

/// Orchestrates E2EE message send/receive for 1:1 + group conversations,
/// including onion-routed delivery and disappearing-message TTLs.
class ChatService {
  final AuthService _auth;
  ChatService(this._auth);

  /// Pick N random "relay" identities from the server's pool.
  /// In v1.0 we pick from active friends (since the server doesn't expose
  /// a directory of all identities). The sender's friend list is the only
  /// available pool — and we exclude the recipient + self.
  List<String> _pickRelays(String recipientId, int count) {
    final pool = _auth.friends
        .map((f) => f.identityId)
        .where((id) => id != recipientId && id != _auth.active!.id)
        .toList()
      ..shuffle();
    return pool.take(count).toList();
  }

  /// Encrypt + send a text message. If [onionRouted] is true (or the friend
  /// has onionRouted=true), wraps the message in N relay layers.
  Future<String> sendText(String peerId, String text,
      {bool? onionRouted}) async {
    final peer = _auth.friend(peerId);
    if (peer == null) throw StateError('peer not in friends list');
    final key = await _auth.sharedKeyWith(peerId, Uint8List.fromList(peer.publicKey));
    final enc = await SendCrypto.encrypt(
      key: key,
      plaintext: Uint8List.fromList(utf8.encode(text)),
    );
    final shouldOnion = onionRouted ?? peer.onionRouted;
    if (shouldOnion) {
      return _sendOnion(
        recipientId: peerId,
        recipientPubKey: Uint8List.fromList(peer.publicKey),
        innerCiphertext: enc.ciphertext,
        innerIv: enc.iv,
        innerKind: MessageKind.text.wire,
      );
    }
    return SupabaseBackend.sendMessage(
      toIdentity: peerId,
      ciphertext: enc.ciphertext,
      iv: enc.iv,
      kind: MessageKind.text.wire,
      ttlSeconds: peer.disappearingTtlSeconds,
    );
  }

  /// Encrypt + send an attachment (image/pdf/voice) + caption.
  Future<String> sendAttachment({
    required String peerId,
    required Uint8List fileBytes,
    required String fileExt,
    required MessageKind kind,
    required String caption,
    bool? onionRouted,
  }) async {
    final peer = _auth.friend(peerId);
    if (peer == null) throw StateError('peer not in friends list');
    final key = await _auth.sharedKeyWith(peerId, Uint8List.fromList(peer.publicKey));

    final encFile = await SendCrypto.encrypt(key: key, plaintext: fileBytes);
    final storedBytes =
        Uint8List.fromList([...encFile.iv, ...encFile.ciphertext]);

    final path = await SupabaseBackend.uploadAttachment(
      identityId: _auth.active!.id,
      peerId: peerId,
      encryptedBytes: storedBytes,
      fileExt: fileExt,
    );

    final payload = jsonEncode({'path': path, 'caption': caption});
    final enc = await SendCrypto.encrypt(
      key: key,
      plaintext: Uint8List.fromList(utf8.encode(payload)),
    );
    final shouldOnion = onionRouted ?? peer.onionRouted;
    if (shouldOnion) {
      return _sendOnion(
        recipientId: peerId,
        recipientPubKey: Uint8List.fromList(peer.publicKey),
        innerCiphertext: enc.ciphertext,
        innerIv: enc.iv,
        innerKind: kind.wire,
        innerAttachmentPath: path,
      );
    }
    return SupabaseBackend.sendMessage(
      toIdentity: peerId,
      ciphertext: enc.ciphertext,
      iv: enc.iv,
      kind: kind.wire,
      attachmentPath: path,
      ttlSeconds: peer.disappearingTtlSeconds,
    );
  }

  /// Onion-route a message through N relays. The inner ciphertext is the
  /// already-encrypted payload for the recipient (under the shared ECDH
  /// key). Each relay gets its own layer encrypted under the shared ECDH
  /// key between the sender and that relay.
  Future<String> _sendOnion({
    required String recipientId,
    required Uint8List recipientPubKey,
    required Uint8List innerCiphertext,
    required Uint8List innerIv,
    required String innerKind,
    String? innerAttachmentPath,
  }) async {
    final relayIds = _pickRelays(recipientId, 2);
    // If we don't have enough friends to use as relays, fall back to direct.
    if (relayIds.length < 2) {
      return SupabaseBackend.sendMessage(
        toIdentity: recipientId,
        ciphertext: innerCiphertext,
        iv: innerIv,
        kind: innerKind,
        attachmentPath: innerAttachmentPath,
      );
    }

    // Build path: [relay1, relay2, recipient]
    final path = <({String id, Uint8List pubKey})>[
      for (final rid in relayIds)
        (id: rid, pubKey: Uint8List.fromList(_auth.friend(rid)!.publicKey)),
      (id: recipientId, pubKey: recipientPubKey),
    ];

    // Derive shared key with each path member.
    final sharedKeys = <Uint8List>[];
    for (final p in path) {
      sharedKeys.add(await _auth.sharedKeyWith(p.id, p.pubKey));
    }

    // Wrap onion.
    final onion = await SendCrypto.wrapOnion(
      path: path,
      sharedKeys: sharedKeys,
      innerCiphertext: innerCiphertext,
      innerIv: innerIv,
      innerKind: innerKind,
      innerAttachmentPath: innerAttachmentPath,
      originalSenderId: _auth.active!.id,
    );

    // Enqueue outer envelope for relay1.
    return SupabaseBackend.relaySend(
      toIdentity: path.first.id,
      ciphertext: onion.ciphertext,
      iv: onion.iv,
      finalKind: innerKind,
      finalAttachmentPath: innerAttachmentPath,
    );
  }

  /// Process relay hops addressed to me. For each hop:
  ///   - Decrypt outer layer with my shared key with the SENDER.
  ///   - But we don't know who the sender is — the from_identity is spoofed
  ///     to me. So we try the SHARED KEY with each friend + self.
  ///   - Actually the outer envelope was encrypted with the shared key
  ///     between the original sender and me. Since the sender is hidden,
  ///     we need to brute-force which friend's key works.
  ///
  /// For v1.0 simplicity: we try decrypting with the shared key of each
  /// friend. The MAC check on AES-GCM will tell us which one is correct.
  /// (This is O(N) but N is small for a chat app.)
  Future<void> processRelayHops() async {
    if (_auth.active == null) return;
    try {
      final hops = await SupabaseBackend.fetchRelayInbox(null);
      for (final hop in hops) {
        final hopId = hop['id'] as String;
        final ct = _parseBytea(hop['ciphertext']);
        final iv = _parseBytea(hop['iv']);
        await _tryProcessHop(hopId, ct, iv);
      }
    } catch (_) {}
  }

  Future<void> _tryProcessHop(String hopId, Uint8List ct, Uint8List iv) async {
    // Try each friend's shared key
    for (final f in _auth.friends) {
      try {
        final key = await _auth.sharedKeyWith(
            f.identityId, Uint8List.fromList(f.publicKey));
        final peeled = await SendCrypto.unwrapOnionLayer(
          sharedKey: key,
          ciphertext: ct,
          iv: iv,
        );
        if (peeled.type == 'relay') {
          // Forward to next hop
          await SupabaseBackend.relaySend(
            toIdentity: peeled.nextHop!,
            ciphertext: peeled.payloadCt!,
            iv: peeled.payloadIv!,
          );
        } else {
          // Final delivery — write into messages table on behalf of original sender
          await SupabaseBackend.relayDeliverFinal(
            toIdentity: _auth.active!.id,
            fromIdentity: peeled.originalSender!,
            ciphertext: peeled.msgCiphertext!,
            iv: peeled.msgIv!,
            kind: peeled.msgKind!,
            attachmentPath: peeled.attachmentPath,
          );
        }
        await SupabaseBackend.relayConsume(hopId);
        return; // done with this hop
      } catch (_) {
        // wrong key — try next friend
        continue;
      }
    }
    // If no friend key worked, this might be a self-loop test or invalid.
    // Consume it to avoid infinite retries.
    try {
      await SupabaseBackend.relayConsume(hopId);
    } catch (_) {}
  }

  /// Decrypt a freshly-arrived message row from Realtime / fetch.
  Future<Message> decryptRow(Map<String, dynamic> row) async {
    final fromId = row['from_identity'] as String;
    final peer = _auth.friend(fromId);
    if (peer == null) {
      throw StateError('message from unknown peer $fromId');
    }
    final key = await _auth.sharedKeyWith(fromId, Uint8List.fromList(peer.publicKey));

    final ciphertext = _parseBytea(row['ciphertext']);
    final iv = _parseBytea(row['iv']);

    String text;
    final kind = MessageKindX.fromWire(row['kind'] as String);
    final deletedAt = row['deleted_at'];
    if (deletedAt != null) {
      return Message(
        id: row['id'] as String,
        fromIdentity: fromId,
        toIdentity: row['to_identity'] as String,
        plaintext: '🚫 Message deleted',
        kind: MessageKind.system,
        attachmentPath: null,
        createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
        deliveredAt: _parseDate(row['delivered_at']),
        readAt: _parseDate(row['read_at']),
        deletedForEveryone: true,
        deletedByIdentity: row['deleted_by'] as String?,
        ttlSeconds: row['ttl_seconds'] as int?,
      );
    }

    final plaintext = await SendCrypto.decrypt(
        key: key, ciphertext: ciphertext, iv: iv);

    if (kind != MessageKind.text) {
      try {
        final p = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
        text = (p['caption'] as String?) ?? '';
      } catch (_) {
        text = '';
      }
    } else {
      text = utf8.decode(plaintext);
    }

    return Message(
      id: row['id'] as String,
      fromIdentity: fromId,
      toIdentity: row['to_identity'] as String,
      plaintext: text,
      kind: kind,
      attachmentPath: row['attachment_path'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      deliveredAt: _parseDate(row['delivered_at']),
      readAt: _parseDate(row['read_at']),
      ttlSeconds: row['ttl_seconds'] as int?,
    );
  }

  DateTime? _parseDate(dynamic v) =>
      v == null ? null : DateTime.parse(v as String).toLocal();

  /// Decrypt a group message row.
  Future<Message> decryptGroupRow(
      Map<String, dynamic> row, String groupId, String creatorId) async {
    final fromId = row['from_identity'] as String;
    final key = await _auth.groupKey(groupId, creatorId);
    final ciphertext = _parseBytea(row['ciphertext']);
    final iv = _parseBytea(row['iv']);

    String text;
    final kind = MessageKindX.fromWire(row['kind'] as String);
    final deletedAt = row['deleted_at'];
    if (deletedAt != null) {
      return Message(
        id: row['id'] as String,
        fromIdentity: fromId,
        toIdentity: _auth.active!.id,
        plaintext: '🚫 Message deleted',
        kind: MessageKind.system,
        attachmentPath: null,
        createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
        groupId: groupId,
      );
    }
    final plaintext =
        await SendCrypto.decrypt(key: key, ciphertext: ciphertext, iv: iv);
    if (kind != MessageKind.text) {
      try {
        final p = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
        text = (p['caption'] as String?) ?? '';
      } catch (_) {
        text = '';
      }
    } else {
      text = utf8.decode(plaintext);
    }
    return Message(
      id: row['id'] as String,
      fromIdentity: fromId,
      toIdentity: _auth.active!.id,
      plaintext: text,
      kind: kind,
      attachmentPath: row['attachment_path'] as String?,
      createdAt: DateTime.parse(row['created_at'] as String).toLocal(),
      groupId: groupId,
    );
  }

  /// Send a group message: encrypts once with the group key, then sends
  /// one ciphertext per recipient.
  Future<String> sendGroupMessage({
    required String groupId,
    required String creatorId,
    required List<String> recipients,
    required String text,
    MessageKind kind = MessageKind.text,
    Uint8List? fileBytes,
    String? fileExt,
    String caption = '',
  }) async {
    final key = await _auth.groupKey(groupId, creatorId);
    String? attachmentPath;
    Uint8List plaintextPayload;
    if (kind == MessageKind.text) {
      plaintextPayload = Uint8List.fromList(utf8.encode(text));
    } else {
      // Encrypt file with same key, prepend iv (12 bytes)
      final encFile = await SendCrypto.encrypt(key: key, plaintext: fileBytes!);
      final storedBytes =
          Uint8List.fromList([...encFile.iv, ...encFile.ciphertext]);
      attachmentPath = await SupabaseBackend.uploadAttachment(
        identityId: _auth.active!.id,
        peerId: 'group_$groupId',
        encryptedBytes: storedBytes,
        fileExt: fileExt!,
      );
      final payload = jsonEncode({'path': attachmentPath, 'caption': caption});
      plaintextPayload = Uint8List.fromList(utf8.encode(payload));
    }
    // Encrypt once per recipient with same key (different IV each).
    final cts = <Uint8List>[];
    final ivs = <Uint8List>[];
    for (final _ in recipients) {
      final enc = await SendCrypto.encrypt(key: key, plaintext: plaintextPayload);
      cts.add(enc.ciphertext);
      ivs.add(enc.iv);
    }
    return SupabaseBackend.sendGroupMessage(
      groupId: groupId,
      recipients: recipients,
      ciphertexts: cts,
      ivs: ivs,
      kind: kind.wire,
      attachmentPath: attachmentPath,
    );
  }

  /// Download + decrypt an attachment's bytes for in-app viewing.
  /// The first 12 bytes of the stored blob are the iv; the rest is ciphertext.
  Future<Uint8List> downloadAttachment(Message m) async {
    if (m.attachmentPath == null) throw StateError('no attachment');
    final key = m.groupId != null
        ? await _auth.groupKey(m.groupId!, _creatorOf(m))
        : await _peerKey(m);
    final storedBytes = await SupabaseBackend.downloadAttachment(m.attachmentPath!);
    if (storedBytes.length < 13) throw StateError('attachment too short');
    final iv = Uint8List.sublistView(storedBytes, 0, 12);
    final ct = Uint8List.sublistView(storedBytes, 12);
    return SendCrypto.decrypt(key: key, ciphertext: ct, iv: iv);
  }

  String _creatorOf(Message m) {
    // Group creator must be passed in by the caller via m.groupId lookup.
    // We can't resolve it here without auth context; caller is expected to
    // use decryptGroupRow which has creatorId. For attachment download,
    // the caller (GroupChatScreen) must call downloadAttachment with the
    // group key directly.
    throw UnimplementedError('use downloadGroupAttachment instead');
  }

  Future<Uint8List> _peerKey(Message m) async {
    final peer = _auth.friend(m.fromIdentity);
    if (peer == null) throw StateError('peer not in friends list');
    return _auth.sharedKeyWith(m.fromIdentity, Uint8List.fromList(peer.publicKey));
  }

  Future<Uint8List> downloadGroupAttachment(
      String groupId, String creatorId, String path) async {
    final key = await _auth.groupKey(groupId, creatorId);
    final storedBytes = await SupabaseBackend.downloadAttachment(path);
    if (storedBytes.length < 13) throw StateError('attachment too short');
    final iv = Uint8List.sublistView(storedBytes, 0, 12);
    final ct = Uint8List.sublistView(storedBytes, 12);
    return SendCrypto.decrypt(key: key, ciphertext: ct, iv: iv);
  }

  /// PostgREST returns `bytea` columns as `\x<hex>` strings. Because we
  /// send bytea RPC params as base64-encoded strings, Postgres stores the
  /// UTF-8 bytes of that base64 string. Use [SupabaseBackend.parseBytea]
  /// which handles the full round-trip (hex → utf8 → base64 → raw bytes).
  static Uint8List _parseBytea(dynamic v) =>
      SupabaseBackend.parseBytea(v);
}
