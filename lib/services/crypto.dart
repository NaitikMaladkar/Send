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
}
