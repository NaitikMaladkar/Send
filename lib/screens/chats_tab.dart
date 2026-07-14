import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/notification_service.dart';
import '../services/supabase_backend.dart';
import 'chat_screen.dart';

/// Lists all friends; tap to open the conversation.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});
  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  RealtimeChannel? _msgChannel;
  RealtimeChannel? _frChannel;
  RealtimeChannel? _frUpdateChannel;
  final Map<String, String> _lastMessage = {}; // peerId -> preview
  final Map<String, DateTime> _lastTime = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _setup() async {
    final auth = context.read<AuthService>();
    if (!auth.hasIdentity) return;
    final id = auth.active!.id;

    // Pull existing inbox to seed previews
    try {
      final inbox = await SupabaseBackend.fetchInbox(null);
      for (final row in inbox) {
        final peerId = row['from_identity'] as String;
        _lastTime[peerId] = DateTime.parse(row['created_at'] as String).toLocal();
        _lastMessage[peerId] = 'Encrypted message';
      }
    } catch (_) {}

    // Subscribe to incoming messages
    _msgChannel = SupabaseBackend.subscribeMessages(
      identityId: id,
      onInsert: (row) async {
        final peerId = row['from_identity'] as String;
        try {
          final m = await context.read<ChatService>().decryptRow(row);
          _lastMessage[peerId] = m.kind == MessageKind.text
              ? m.plaintext
              : 'Attachment: ${m.kind.name}';
          _lastTime[peerId] = m.createdAt;
          // mark delivered
          await SupabaseBackend.markDelivered(m.id);
          // Notify (no plaintext in notification body for privacy)
          await NotificationService.showIncomingMessage(
            preview: m.kind == MessageKind.text ? 'Encrypted message' : 'Attachment',
          );
        } catch (_) {
          _lastMessage[peerId] = 'New encrypted message';
          _lastTime[peerId] = DateTime.now();
          await NotificationService.showIncomingMessage();
        }
        if (mounted) setState(() {});
      },
    );

    // Subscribe to incoming friend requests
    _frChannel = SupabaseBackend.subscribeFriendRequests(
      identityId: id,
      onInsert: (row) async {
        final fromId = row['from_identity'] as String;
        await NotificationService.showFriendRequest(fromId: fromId);
        if (mounted) setState(() {});
      },
    );

    // Subscribe to friend-request updates (someone accepted mine)
    _frUpdateChannel = SupabaseBackend.subscribeFriendRequestUpdates(
      identityId: id,
      onUpdate: (row) async {
        final status = row['status'] as String;
        final otherId = row['to_identity'] as String;
        if (status == 'accepted') {
          // If we don't have this friend cached yet, fetch their pubkey
          // and add them. This handles the case where the OTHER side accepted
          // our request — we need their pubkey to encrypt to them.
          if (auth.friend(otherId) == null) {
            try {
              final pub = await SupabaseBackend.fetchIdentityPublicKey(otherId);
              await auth.addFriend(Friend(
                identityId: otherId,
                publicKey: pub.toList(),
                alias: null,
                friendedAt: DateTime.now(),
              ));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Your friend request was accepted')),
                );
              }
            } catch (_) {}
          }
        }
      },
    );

    // One-shot poll for any outgoing requests that were accepted while we
    // were offline (Realtime only fires for live UPDATEs, not past state).
    try {
      final outgoing = await SupabaseBackend.fetchOutgoingFriendRequests();
      for (final row in outgoing) {
        if (row['status'] != 'accepted') continue;
        final otherId = row['to_identity'] as String;
        if (auth.friend(otherId) != null) continue;
        try {
          final pub = await SupabaseBackend.fetchIdentityPublicKey(otherId);
          await auth.addFriend(Friend(
            identityId: otherId,
            publicKey: pub.toList(),
            alias: null,
            friendedAt: DateTime.now(),
          ));
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _msgChannel?.unsubscribe();
    _frChannel?.unsubscribe();
    _frUpdateChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final friends = auth.friends;
    if (friends.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 64, color: Colors.white24),
            const SizedBox(height: 16),
            const Text('No conversations yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Open the Friends tab to add someone\nvia their rotating code.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      itemCount: friends.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white10),
      itemBuilder: (context, i) {
        final f = friends[i];
        final preview = _lastMessage[f.identityId] ?? 'Tap to chat';
        final time = _lastTime[f.identityId];
        return ListTile(
          leading: CircleAvatar(
            backgroundColor: Theme.of(context).colorScheme.primary,
            child: Text(
              (f.alias?.isNotEmpty ?? false) ? f.alias![0].toUpperCase() : '#',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          title: Text(f.alias ?? f.identityId.substring(0, 8)),
          subtitle: Text(preview, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Text(
            time != null ? '${time.hour}:${time.minute.toString().padLeft(2, '0')}' : '',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ChatScreen(friend: f)),
          ),
        );
      },
    );
  }
}
