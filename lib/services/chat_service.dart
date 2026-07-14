import 'dart:convert';
import 'dart:typed_data';

import '../models/message.dart';
import 'auth_service.dart';
import 'crypto.dart';
import 'supabase_backend.dart';

/// Orchestrates E2EE message send/receive for a 1:1 conversation.
class ChatService {
  final AuthService _auth;
  ChatService(this._auth);

  /// Encrypt + send a text message.
  Future<String> sendText(String peerId, String text) async {
    final peer = _auth.friend(peerId);
    if (peer == null) throw StateError('peer not in friends list');
    final key = await _auth.sharedKeyWith(peerId, Uint8List.fromList(peer.publicKey));
    final enc = await SendCrypto.encrypt(
      key: key,
      plaintext: Uint8List.fromList(utf8.encode(text)),
    );
    return SupabaseBackend.sendMessage(
      toIdentity: peerId,
      ciphertext: enc.ciphertext,
      iv: enc.iv,
      kind: MessageKind.text.wire,
    );
  }

  /// Encrypt + send an attachment (image/pdf/voice) + caption.
  ///
  /// The file is encrypted with the shared ECDH key + a fresh AES-GCM iv.
  /// To avoid an extra round-trip, the iv is prepended to the ciphertext
  /// in storage: `iv(12 bytes) || ciphertext`. The message's text payload
  /// is just the path + caption (also encrypted, with its own iv per row).
  Future<String> sendAttachment({
    required String peerId,
    required Uint8List fileBytes,
    required String fileExt,
    required MessageKind kind,
    required String caption,
  }) async {
    final peer = _auth.friend(peerId);
    if (peer == null) throw StateError('peer not in friends list');
    final key = await _auth.sharedKeyWith(peerId, Uint8List.fromList(peer.publicKey));

    final encFile = await SendCrypto.encrypt(key: key, plaintext: fileBytes);
    // Concatenate iv + ciphertext for storage (12-byte prefix)
    final storedBytes = Uint8List.fromList([...encFile.iv, ...encFile.ciphertext]);

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
    return SupabaseBackend.sendMessage(
      toIdentity: peerId,
      ciphertext: enc.ciphertext,
      iv: enc.iv,
      kind: kind.wire,
      attachmentPath: path,
    );
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
    final plaintext = await SendCrypto.decrypt(key: key, ciphertext: ciphertext, iv: iv);

    String text;
    final kind = MessageKindX.fromWire(row['kind'] as String);
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
      deliveredAt: row['delivered_at'] == null
          ? null
          : DateTime.parse(row['delivered_at'] as String).toLocal(),
      readAt: row['read_at'] == null
          ? null
          : DateTime.parse(row['read_at'] as String).toLocal(),
    );
  }

  /// PostgREST returns `bytea` columns in different shapes depending on the
  /// Accept / arrayheader configuration. Handle them all.
  static Uint8List _parseBytea(dynamic v) {
    if (v is Uint8List) return v;
    if (v is List) return Uint8List.fromList(List<int>.from(v));
    if (v is String) {
      // Realtime payloads arrive as base64 string
      try {
        return base64Decode(v);
      } catch (_) {
        // Could be \x hex
        if (v.startsWith(r'\x')) {
          final hex = v.substring(2);
          return Uint8List.fromList(
            List<int>.generate(hex.length ~/ 2, (i) {
              return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
            }),
          );
        }
        rethrow;
      }
    }
    if (v is Map && v['data'] is List) {
      return Uint8List.fromList(List<int>.from(v['data']));
    }
    throw StateError('cannot parse bytea: $v (${v.runtimeType})');
  }

  /// Download + decrypt an attachment's bytes for in-app viewing.
  /// The first 12 bytes of the stored blob are the iv; the rest is ciphertext.
  Future<Uint8List> downloadAttachment(Message m) async {
    if (m.attachmentPath == null) throw StateError('no attachment');
    final peer = _auth.friend(m.fromIdentity);
    if (peer == null) throw StateError('peer not in friends list');
    final key = await _auth.sharedKeyWith(m.fromIdentity, Uint8List.fromList(peer.publicKey));
    final storedBytes = await SupabaseBackend.downloadAttachment(m.attachmentPath!);
    if (storedBytes.length < 13) throw StateError('attachment too short');
    final iv = Uint8List.sublistView(storedBytes, 0, 12);
    final ct = Uint8List.sublistView(storedBytes, 12);
    return SendCrypto.decrypt(key: key, ciphertext: ct, iv: iv);
  }
}
