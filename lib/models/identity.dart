import 'dart:typed_data';

/// Local representation of a Send account.
///
/// `id` (uuid) and `authToken` come from the server's `signup()` or `signin()`
/// RPC. `publicId` is the sequential 8-digit account number (e.g. 1 → "ID:00000001").
/// `displayName` is the non-unique name shown to friends. `privateKey` is the
/// X25519 seed, kept ONLY on-device in flutter_secure_storage (Android Keystore).
/// `passkeySalt` is the random salt used to derive the passkey→key that encrypts
/// the private key blob uploaded to the server for re-login.
class Identity {
  final String id;
  final String authToken;
  final int publicId;
  final String displayName;
  final Uint8List publicKey;
  final Uint8List privateKey;

  /// Salt used by PBKDF2(passkey) to derive the AES key that encrypts the
  /// private key blob on the server. Kept locally so that future re-encrypt
  /// operations don't need to re-prompt for the passkey.
  final Uint8List passkeySalt;

  const Identity({
    required this.id,
    required this.authToken,
    required this.publicId,
    required this.displayName,
    required this.publicKey,
    required this.privateKey,
    required this.passkeySalt,
  });

  /// Format the public ID as the user-facing string: "ID:00000001".
  String get displayId => 'ID:${publicId.toString().padLeft(8, '0')}';

  Map<String, dynamic> toJson() => {
        'id': id,
        'authToken': authToken,
        'publicId': publicId,
        'displayName': displayName,
        'publicKey': publicKey.toList(),
        'privateKey': privateKey.toList(),
        'passkeySalt': passkeySalt.toList(),
      };

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        id: j['id'] as String,
        authToken: j['authToken'] as String,
        publicId: (j['publicId'] is int)
            ? j['publicId'] as int
            : int.parse('${j['publicId']}'),
        displayName: j['displayName'] as String? ?? '',
        publicKey: Uint8List.fromList(List<int>.from(j['publicKey'] as List)),
        privateKey: Uint8List.fromList(List<int>.from(j['privateKey'] as List)),
        passkeySalt: Uint8List.fromList(
            List<int>.from((j['passkeySalt'] ?? j['passkey_salt'] ?? const []) as List)),
      );
}
