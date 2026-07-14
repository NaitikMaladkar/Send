import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/group.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/haptic_service.dart';
import '../services/supabase_backend.dart';
import '../widgets/empty_state.dart';

class GroupChatScreen extends StatefulWidget {
  final Group group;
  const GroupChatScreen({super.key, required this.group});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Message> _messages = [];
  RealtimeChannel? _channel;
  Timer? _poll;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _setup() async {
    final auth = context.read<AuthService>();
    final chat = context.read<ChatService>();
    final id = auth.active!.id;
    final gid = widget.group.id;

    // Initial backfill: fetch all group inbox and filter to this group
    try {
      final rows = await SupabaseBackend.fetchGroupInbox(null);
      for (final row in rows) {
        if (row['group_id'] != gid) continue;
        try {
          final m = await chat.decryptGroupRow(row, gid, widget.group.createdBy);
          _messages.add(m);
        } catch (_) {}
      }
      _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      if (mounted) setState(() {});
    } catch (_) {}

    _channel = SupabaseBackend.subscribeGroupMessages(
      identityId: id,
      onInsert: (row) async {
        if (row['group_id'] != gid) return;
        try {
          final m =
              await chat.decryptGroupRow(row, gid, widget.group.createdBy);
          if (_messages.any((e) => e.id == m.id)) return;
          _messages.add(m);
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          if (mounted) setState(() {});
          _scrollToBottom();
        } catch (_) {}
      },
    );

    _poll = Timer.periodic(const Duration(seconds: 15), (_) async {
      try {
        final since = _messages.isEmpty ? null : _messages.last.createdAt;
        final rows = await SupabaseBackend.fetchGroupInbox(since);
        var added = false;
        for (final row in rows) {
          if (row['group_id'] != gid) continue;
          try {
            final m = await chat.decryptGroupRow(row, gid, widget.group.createdBy);
            if (_messages.any((e) => e.id == m.id)) continue;
            _messages.add(m);
            added = true;
          } catch (_) {}
        }
        if (added) {
          _messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          if (mounted) setState(() {});
          _scrollToBottom();
        }
      } catch (_) {}
    });
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(0,
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut);
        }
      });
    }
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

    final optimistic = Message(
      id: 'pending-${DateTime.now().millisecondsSinceEpoch}',
      fromIdentity: auth.active!.id,
      toIdentity: auth.active!.id,
      plaintext: text,
      kind: MessageKind.text,
      createdAt: DateTime.now(),
      groupId: widget.group.id,
    );
    _messages.add(optimistic);
    setState(() {});
    _scrollToBottom();

    try {
      await chat.sendGroupMessage(
        groupId: widget.group.id,
        creatorId: widget.group.createdBy,
        recipients: widget.group.memberIds,
        text: text,
      );
      await HapticService.sent();
    } catch (e) {
      await HapticService.error();
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.group.name),
            Text('${widget.group.memberIds.length} members',
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Leave group?'),
                  content: const Text(
                      'You will no longer receive messages from this group.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Leave',
                            style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirmed != true) return;
              try {
                await SupabaseBackend.leaveGroup(widget.group.id);
                await auth.refreshGroups();
                if (mounted) Navigator.pop(context);
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed: $e')));
                }
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty
                ? const EmptyState(
                    icon: Icons.group,
                    title: 'No messages yet',
                    subtitle: 'Start the conversation — everyone in this\ngroup shares one encrypted key.',
                  )
                : ListView.builder(
                    controller: _scroll,
                    reverse: true,
                    itemCount: _messages.length,
                    itemBuilder: (context, i) {
                      final m = _messages[_messages.length - 1 - i];
                      final isMine = m.fromIdentity == auth.active!.id;
                      return _bubble(m, isMine, auth);
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
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
                            width: 20,
                            height: 20,
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

  Widget _bubble(Message m, bool isMine, AuthService auth) {
    final sender = auth.friend(m.fromIdentity);
    final senderName = sender?.alias ?? m.fromIdentity.substring(0, 8);
    final theme = Theme.of(context);
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
              ? theme.colorScheme.primary
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMine)
              Text(senderName,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.secondary)),
            Text(m.plaintext,
                style: TextStyle(
                    fontSize: 15,
                    color:
                        isMine ? Colors.white : theme.textTheme.bodyLarge?.color)),
            const SizedBox(height: 2),
            Text(
              '${m.createdAt.hour}:${m.createdAt.minute.toString().padLeft(2, '0')}',
              style: TextStyle(
                  fontSize: 10,
                  color: isMine ? Colors.white54 : theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}
