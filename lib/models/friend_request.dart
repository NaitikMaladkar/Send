/// A friend request — either pending, accepted, or rejected.
class FriendRequest {
  final String id;
  final String fromIdentity;
  final String toIdentity;
  final String? intro;
  final String status; // pending | accepted | rejected
  final DateTime createdAt;
  final DateTime? respondedAt;

  const FriendRequest({
    required this.id,
    required this.fromIdentity,
    required this.toIdentity,
    this.intro,
    required this.status,
    required this.createdAt,
    this.respondedAt,
  });
}
