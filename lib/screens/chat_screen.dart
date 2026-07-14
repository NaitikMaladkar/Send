import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/supabase_backend.dart';

class ChatScreen extends StatefulWidget {
  final Friend friend;
  const ChatScreen({super.key, required this.friend});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Message> _messages = [];
  RealtimeChannel? _channel;
  bool _sending = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _setup() async {
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    final id = auth.active!.id;
    final peerId = widget.friend.identityId;

    // Initial backfill — fetch all inbox then filter to THIS peer
    // (server doesn't yet support per-peer fetch; future RPC could).
    try {
      final rows = await SupabaseBackend.fetchInbox(null);
      for (final row in rows) {
        final from = row['from_identity'] as String;
        final to = row['to_identity'] as String;
        // Show messages FROM this peer TO me, OR FROM me TO this peer.
        if (from != peerId && to != peerId) continue;
        try {
          final m = await chat.decryptRow(row);
          _messages.add(m);
        } catch (_) {}
      }
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (mounted) setState(() {});
    } catch (_) {}

    // Realtime for incoming
    _channel = SupabaseBackend.subscribeMessages(
      identityId: id,
      onInsert: (row) async {
        if (row['from_identity'] != peerId) return;
        try {
          final m = await chat.decryptRow(row);
          // Dedup
          if (_messages.any((e) => e.id == m.id)) return;
          _messages.add(m);
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          await SupabaseBackend.markRead(m.id);
          if (mounted) setState(() {});
          if (_scroll.hasClients) {
            _scroll.animateTo(0,
                duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
          }
        } catch (_) {}
      },
    );

    // Fallback poll in case Realtime misses (every 15s)
    _poll = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final since = _messages.isEmpty ? null : _messages.last.createdAt;
        final rows = await SupabaseBackend.fetchInbox(since);
        for (final row in rows) {
          if (row['from_identity'] != peerId) continue;
          try {
            final m = await chat.decryptRow(row);
            if (_messages.any((e) => e.id == m.id)) continue;
            _messages.add(m);
            await SupabaseBackend.markRead(m.id);
          } catch (_) {}
        }
        _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (mounted) setState(() {});
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    setState(() => _sending = true);
    _input.clear();
    // Optimistic insert
    final optimistic = Message(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      fromIdentity: auth.active!.id,
      toIdentity: widget.friend.identityId,
      plaintext: text,
      kind: MessageKind.text,
      createdAt: DateTime.now(),
    );
    _messages.add(optimistic);
    setState(() {});
    try {
      await chat.sendText(widget.friend.identityId, text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Send failed: $e')));
        _messages.remove(optimistic);
        _input.text = text;
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (x == null) return;
    final bytes = await x.readAsBytes();
    _sendAttachment(Uint8List.fromList(bytes), 'img', MessageKind.image);
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result == null || result.files.single.bytes == null) {
      // On Android, path may be available instead
      if (result?.files.single.path != null) {
        final bytes = await File(result!.files.single.path!).readAsBytes();
        _sendAttachment(Uint8List.fromList(bytes), 'pdf', MessageKind.pdf);
      }
      return;
    }
    _sendAttachment(Uint8List.fromList(result.files.single.bytes!), 'pdf', MessageKind.pdf);
  }

  Future<void> _sendAttachment(Uint8List bytes, String ext, MessageKind kind) async {
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    setState(() => _sending = true);
    try {
      await chat.sendAttachment(
        peerId: widget.friend.identityId,
        fileBytes: bytes,
        fileExt: ext,
        kind: kind,
        caption: '[${kind.name}]',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Upload failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.friend.alias ?? widget.friend.identityId.substring(0, 8)),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              reverse: true,
              itemCount: _messages.length,
              itemBuilder: (context, i) {
                final m = _messages[_messages.length - 1 - i];
                final isMine = m.fromIdentity == context.read<AuthService>().active!.id;
                return _bubble(m, isMine);
              },
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.image_outlined), onPressed: _pickImage),
                  IconButton(icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: _pickPdf),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Encrypted message…',
                        isDense: true,
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(
                    icon: _sending
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.send),
                    onPressed: _sending ? null : _send,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bubble(Message m, bool isMine) {
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMine
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (m.kind != MessageKind.text)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.kind == MessageKind.image ? Icons.image : Icons.picture_as_pdf,
                        size: 16, color: Colors.white70),
                    const SizedBox(width: 6),
                    Text('${m.kind.name} attached',
                        style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ],
                ),
              ),
            Text(
              m.plaintext.isEmpty && m.kind != MessageKind.text
                  ? '[${m.kind.name}]'
                  : m.plaintext,
              style: const TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 2),
            Text(
              '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 10, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}
