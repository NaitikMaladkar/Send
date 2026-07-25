enum MessageKind { text, image, pdf, voice, system }

extension MessageKindX on MessageKind {
  String get wire => switch (this) {
        MessageKind.text => 'text',
        MessageKind.image => 'image',
        MessageKind.pdf => 'pdf',
        MessageKind.voice => 'voice',
        MessageKind.system => 'system',
      };

  static MessageKind fromWire(String s) => switch (s) {
        'text' => MessageKind.text,
        'image' => MessageKind.image,
        'pdf' => MessageKind.pdf,
        'voice' => MessageKind.voice,
        'system' => MessageKind.system,
        _ => MessageKind.text,
      };
}

/// A decrypted message displayed in chat.
class Message {
  final String id;
  final String fromIdentity;
  final String toIdentity;
  final String plaintext;
  final MessageKind kind;
  final String? attachmentPath; // remote storage path
  final DateTime createdAt;
  final DateTime? deliveredAt;
  final DateTime? readAt;

  /// True if sender deleted this message for everyone (ciphertext wiped).
  final bool deletedForEveryone;
  final String? deletedByIdentity;

  /// Group id if this message belongs to a group chat (else null).
  final String? groupId;

  /// Disappearing TTL in seconds (used for the countdown UI).
  final int? ttlSeconds;

  const Message({
    required this.id,
    required this.fromIdentity,
    required this.toIdentity,
    required this.plaintext,
    required this.kind,
    this.attachmentPath,
    required this.createdAt,
    this.deliveredAt,
    this.readAt,
    this.deletedForEveryone = false,
    this.deletedByIdentity,
    this.groupId,
    this.ttlSeconds,
  });

  Message copyWith({
    String? plaintext,
    DateTime? deliveredAt,
    DateTime? readAt,
    bool? deletedForEveryone,
    String? deletedByIdentity,
  }) =>
      Message(
        id: id,
        fromIdentity: fromIdentity,
        toIdentity: toIdentity,
        plaintext: plaintext ?? this.plaintext,
        kind: kind,
        attachmentPath: attachmentPath,
        createdAt: createdAt,
        deliveredAt: deliveredAt ?? this.deliveredAt,
        readAt: readAt ?? this.readAt,
        deletedForEveryone: deletedForEveryone ?? this.deletedForEveryone,
        deletedByIdentity: deletedByIdentity ?? this.deletedByIdentity,
        groupId: groupId,
        ttlSeconds: ttlSeconds,
      );
}
