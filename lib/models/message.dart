enum MessageKind { text, image, pdf, voice }

extension MessageKindX on MessageKind {
  String get wire => switch (this) {
        MessageKind.text => 'text',
        MessageKind.image => 'image',
        MessageKind.pdf => 'pdf',
        MessageKind.voice => 'voice',
      };

  static MessageKind fromWire(String s) => switch (s) {
        'text' => MessageKind.text,
        'image' => MessageKind.image,
        'pdf' => MessageKind.pdf,
        'voice' => MessageKind.voice,
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
  });

  bool get isMine => false; // set by chat controller
}
