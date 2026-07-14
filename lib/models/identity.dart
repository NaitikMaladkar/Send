import 'dart:typed_data';

/// Local representation of an anonymous identity.
///
/// `id` and `authToken` come from the server's `register_identity()` RPC.
/// `privateKey` never leaves the device; `publicKey` is uploaded once.
class Identity {
  final String id;
  final String authToken;
  final String displayCode;
  final Uint8List publicKey;
  final Uint8List privateKey;

  const Identity({
    required this.id,
    required this.authToken,
    required this.displayCode,
    required this.publicKey,
    required this.privateKey,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'authToken': authToken,
        'displayCode': displayCode,
        'publicKey': publicKey.toList(),
        'privateKey': privateKey.toList(),
      };

  factory Identity.fromJson(Map<String, dynamic> j) => Identity(
        id: j['id'] as String,
        authToken: j['authToken'] as String,
        displayCode: j['displayCode'] as String,
        publicKey: Uint8List.fromList(List<int>.from(j['publicKey'] as List)),
        privateKey: Uint8List.fromList(List<int>.from(j['privateKey'] as List)),
      );
}
