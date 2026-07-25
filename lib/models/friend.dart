/// A friend — identity id + a locally-cached public key + alias.
class Friend {
  final String identityId;
  final List<int> publicKey;
  final String? alias;
  final DateTime friendedAt;

  /// Per-friend disappearing-messages TTL override (seconds).
  /// null = use my default.
  final int? disappearingTtlSeconds;

  /// Per-friend onion-routing toggle. If true, messages to this friend
  /// are wrapped in [OnionConfig.relayCount] relay layers.
  final bool onionRouted;

  const Friend({
    required this.identityId,
    required this.publicKey,
    this.alias,
    required this.friendedAt,
    this.disappearingTtlSeconds,
    this.onionRouted = false,
  });

  Friend copyWith({
    String? alias,
    int? disappearingTtlSeconds,
    bool? onionRouted,
  }) =>
      Friend(
        identityId: identityId,
        publicKey: publicKey,
        alias: alias ?? this.alias,
        friendedAt: friendedAt,
        disappearingTtlSeconds:
            disappearingTtlSeconds ?? this.disappearingTtlSeconds,
        onionRouted: onionRouted ?? this.onionRouted,
      );

  Map<String, dynamic> toJson() => {
        'identityId': identityId,
        'publicKey': publicKey,
        'alias': alias,
        'friendedAt': friendedAt.toIso8601String(),
        'disappearingTtlSeconds': disappearingTtlSeconds,
        'onionRouted': onionRouted,
      };

  factory Friend.fromJson(Map<String, dynamic> j) => Friend(
        identityId: j['identityId'] as String,
        publicKey: List<int>.from(j['publicKey'] as List),
        alias: j['alias'] as String?,
        friendedAt: DateTime.parse(j['friendedAt'] as String),
        disappearingTtlSeconds: j['disappearingTtlSeconds'] as int?,
        onionRouted: (j['onionRouted'] as bool?) ?? false,
      );
}
