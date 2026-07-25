/// A group chat — id + name + cached member ids + per-member shared key.
class Group {
  final String id;
  final String name;
  final String createdBy;
  final DateTime createdAt;
  final List<String> memberIds;

  const Group({
    required this.id,
    required this.name,
    required this.createdBy,
    required this.createdAt,
    required this.memberIds,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'createdBy': createdBy,
        'createdAt': createdAt.toIso8601String(),
        'memberIds': memberIds,
      };

  factory Group.fromJson(Map<String, dynamic> j) => Group(
        id: j['id'] as String,
        name: j['name'] as String,
        createdBy: j['createdBy'] as String,
        createdAt: DateTime.parse(j['createdAt'] as String),
        memberIds: List<String>.from(j['memberIds'] as List),
      );
}
