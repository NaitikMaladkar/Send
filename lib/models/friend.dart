/// A friend — identity id + a locally-cached public key + last-known display code.
class Friend {
  final String identityId;
  final List<int> publicKey;
  final String? alias;
  final DateTime friendedAt;

  const Friend({
    required this.identityId,
    required this.publicKey,
    this.alias,
    required this.friendedAt,
  });
}
