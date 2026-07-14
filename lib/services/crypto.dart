import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Send — end-to-end encryption primitives.
///
/// Stack:
///   * X25519 ECDH for key agreement
///   * HKDF-SHA256 (32-byte output) for derived symmetric keys
///   * AES-256-GCM (12-byte nonce, 16-byte tag) for message encryption
///
/// The server never sees plaintext or symmetric keys. Only public keys are
/// uploaded; ciphertext + iv are uploaded together.
class SendCrypto {
  static final X25519 _x25519 = X25519();
  static final AesGcm _aes = AesGcm.with256bits();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static final Sha256 _sha256 = Sha256();

  /// Generate a new X25519 keypair.
  static Future<SimpleKeyPair> generateKeyPair() => _x25519.newKeyPair();

  /// Export public key as raw bytes.
  static Future<Uint8List> exportPublic(SimpleKeyPair kp) async {
    final pub = await kp.extractPublicKey();
    return Uint8List.fromList(pub.bytes);
  }

  /// Export private key (seed) as raw bytes.
  static Future<Uint8List> exportPrivate(SimpleKeyPair kp) async {
    final priv = await kp.extractPrivateKeyBytes();
    return Uint8List.fromList(priv);
  }

  /// Import a private key (seed) back into a keypair.
  static Future<SimpleKeyPair> importPrivate(Uint8List seed) =>
      _x25519.newKeyPairFromSeed(seed);

  /// Build a public-key object from raw bytes (for ECDH with remote peers).
  static SimplePublicKey publicKeyFromBytes(Uint8List bytes) =>
      SimplePublicKey(bytes.toList(), type: KeyPairType.x25519);

  /// Derive a 32-byte symmetric key from ECDH(myPrivate, theirPublic) via
  /// HKDF-SHA256. `info` binds the key to a specific peer pair.
  static Future<Uint8List> deriveSharedKey({
    required SimpleKeyPair myPrivate,
    required Uint8List theirPublic,
    required String info,
  }) async {
    final secret = await _x25519.sharedSecretKey(
      keyPair: myPrivate,
      remotePublicKey: publicKeyFromBytes(theirPublic),
    );
    final derived = await _hkdf.deriveKey(
      secretKey: secret,
      nonce: utf8.encode(info),
    );
    final out = await derived.extractBytes();
    return Uint8List.fromList(out);
  }

  /// Encrypt plaintext with AES-256-GCM. Returns (ciphertext+tag, iv).
  static Future<({Uint8List ciphertext, Uint8List iv})> encrypt({
    required Uint8List key,
    required Uint8List plaintext,
  }) async {
    final secretKey = SecretKey(key.toList());
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(
      plaintext.toList(),
      secretKey: secretKey,
      nonce: nonce,
    );
    // Concatenate ciphertext + MAC so we can split on decrypt
    final ct = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return (ciphertext: ct, iv: Uint8List.fromList(nonce));
  }

  /// Decrypt ciphertext with AES-256-GCM. The last 16 bytes of `ciphertext`
  /// are the GCM tag. Throws on integrity failure.
  static Future<Uint8List> decrypt({
    required Uint8List key,
    required Uint8List ciphertext,
    required Uint8List iv,
  }) async {
    if (ciphertext.length < 16) throw ArgumentError('ciphertext too short');
    final secretKey = SecretKey(key.toList());
    final ct = ciphertext.sublist(0, ciphertext.length - 16);
    final mac = Mac(ciphertext.sublist(ciphertext.length - 16));
    final box = SecretBox(ct, nonce: iv.toList(), mac: mac);
    final pt = await _aes.decrypt(box, secretKey: secretKey);
    return Uint8List.fromList(pt);
  }

  /// SHA-256 of a string → 32-byte digest.
  static Future<Uint8List> sha256Bytes(String s) async {
    final h = await _sha256.hash(utf8.encode(s));
    return Uint8List.fromList(h.bytes);
  }

  /// Random 32-byte symmetric key — used for group chat keys.
  static Future<Uint8List> generateSymmetricKey() async {
    final r = DateTime.now().microsecondsSinceEpoch;
    final seed = Uint8List.fromList([
      ...utf8.encode('send-group-key-$r'),
      ...List<int>.generate(32, (i) => (r >> (i % 8)) & 0xff),
    ]);
    final h = await _sha256.hash(seed);
    return Uint8List.fromList(h.bytes);
  }

  // ============================================================
  //  Onion routing — layered envelope helpers.
  //
  //  An onion envelope is a chain of AES-GCM layers. Each layer's
  //  plaintext is JSON: {"next_hop": "<uuid>", "payload": "<base64>"}.
  //  The innermost layer's plaintext is the real message ciphertext
  //  that the recipient will decrypt with the shared ECDH key.
  //
  //  Path: [relay1, relay2, recipient]. Each relay shares an ECDH
  //  key with the SENDER (not the recipient). Each layer is encrypted
  //  with that relay's shared key.
  // ============================================================

  /// Build a 3-layer onion envelope. `pathPubKeys` is the list of
  /// (peer_id, peer_pubkey) tuples in order: [relay1, relay2, recipient].
  ///
  /// Returns the outermost ciphertext + iv (for relay1).
  static Future<({Uint8List ciphertext, Uint8List iv})> wrapOnion({
    required List<({String id, Uint8List pubKey})> path,
    required List<Uint8List> sharedKeys, // ECDH(me, each path member)
    required Uint8List innerCiphertext, // already-encrypted msg for recipient
    required Uint8List innerIv,
    required String innerKind,
    String? innerAttachmentPath,
    required String originalSenderId,
  }) async {
    if (path.length != sharedKeys.length) {
      throw ArgumentError('path/sharedKeys length mismatch');
    }
    if (path.length < 2) {
      throw ArgumentError('onion path must be >= 2 hops');
    }

    // Innermost layer (for the recipient): contains original_sender +
    // the message ciphertext that they'll decrypt with their own ECDH key.
    final innerPayload = jsonEncode({
      'type': 'final',
      'original_sender': originalSenderId,
      'msg_ciphertext': base64Encode(innerCiphertext),
      'msg_iv': base64Encode(innerIv),
      'msg_kind': innerKind,
      'attachment_path': innerAttachmentPath,
    });

    // Start with the innermost payload, encrypt to the recipient (last in path).
    Uint8List currentCt;
    Uint8List currentIv;
    var enc = await encrypt(
      key: sharedKeys.last,
      plaintext: Uint8List.fromList(utf8.encode(innerPayload)),
    );
    currentCt = enc.ciphertext;
    currentIv = enc.iv;

    // Walk backwards through relays, wrapping each layer with next_hop info.
    for (var i = path.length - 2; i >= 0; i--) {
      final nextHop = path[i + 1].id;
      final layerPayload = jsonEncode({
        'type': 'relay',
        'next_hop': nextHop,
        'payload_ct': base64Encode(currentCt),
        'payload_iv': base64Encode(currentIv),
      });
      enc = await encrypt(
        key: sharedKeys[i],
        plaintext: Uint8List.fromList(utf8.encode(layerPayload)),
      );
      currentCt = enc.ciphertext;
      currentIv = enc.iv;
    }

    return (ciphertext: currentCt, iv: currentIv);
  }

  /// Peel one layer of an onion envelope. Returns either:
  ///   - ("relay", nextHop, innerCiphertext, innerIv, null, null, null) — forward
  ///   - ("final", originalSender, msgCiphertext, msgIv, msgKind, attachmentPath, null) — deliver
  static Future<({
    String type,
    String? nextHop,
    Uint8List? payloadCt,
    Uint8List? payloadIv,
    String? originalSender,
    Uint8List? msgCiphertext,
    Uint8List? msgIv,
    String? msgKind,
    String? attachmentPath,
  })> unwrapOnionLayer({
    required Uint8List sharedKey,
    required Uint8List ciphertext,
    required Uint8List iv,
  }) async {
    final ptBytes = await decrypt(key: sharedKey, ciphertext: ciphertext, iv: iv);
    final j = jsonDecode(utf8.decode(ptBytes)) as Map<String, dynamic>;
    final type = j['type'] as String;
    if (type == 'relay') {
      return (
        type: 'relay',
        nextHop: j['next_hop'] as String,
        payloadCt: base64Decode(j['payload_ct'] as String),
        payloadIv: base64Decode(j['payload_iv'] as String),
        originalSender: null,
        msgCiphertext: null,
        msgIv: null,
        msgKind: null,
        attachmentPath: null,
      );
    } else if (type == 'final') {
      return (
        type: 'final',
        nextHop: null,
        payloadCt: null,
        payloadIv: null,
        originalSender: j['original_sender'] as String,
        msgCiphertext: base64Decode(j['msg_ciphertext'] as String),
        msgIv: base64Decode(j['msg_iv'] as String),
        msgKind: j['msg_kind'] as String,
        attachmentPath: j['attachment_path'] as String?,
      );
    } else {
      throw StateError('unknown onion layer type: $type');
    }
  }
}
