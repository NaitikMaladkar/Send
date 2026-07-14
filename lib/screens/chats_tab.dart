import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/friend.dart';
import '../models/message.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/haptic_service.dart';
import '../services/notification_service.dart';
import '../services/supabase_backend.dart';
import '../widgets/empty_state.dart';
import 'chat_screen.dart';
import 'group_chat_screen.dart';

/// Lists all 1:1 friends + groups; tap to open the conversation.
class ChatsTab extends StatefulWidget {
  const ChatsTab({super.key});
  @override
  State<ChatsTab> createState() => _ChatsTabState();
}

class _ChatsTabState extends State<ChatsTab> {
  RealtimeChannel? _msgChannel;
  RealtimeChannel? _grpChannel;
  RealtimeChannel? _frChannel;
  RealtimeChannel? _frUpdateChannel;
  final Map<String, String> _lastMessage = {}; // peerId -> preview
  final Map<String, DateTime> _lastTime = {};
  final Map<String, int> _unread = {};
  final Map<String, String> _groupLastMessage = {};
  final Map<String, DateTime> _groupLastTime = {};
  final GlobalKey<RefreshIndicatorState> _refreshKey =
      GlobalKey<RefreshIndicatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setup());
  }

  Future<void> _setup() async {
    final auth = context.read<AuthService>();
    if (!auth.hasIdentity) return;
    final id = auth.active!.id;

    await _refreshPreviews();

    // Subscribe to incoming 1:1 messages
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
          _unread[peerId] = (_unread[peerId] ?? 0) + 1;
          await SupabaseBackend.markDelivered(m.id);
          await NotificationService.showIncomingMessage(
            preview: m.kind == MessageKind.text ? 'Encrypted message' : 'Attachment',
          );
          await HapticService.light();
        } catch (_) {
          _lastMessage[peerId] = 'New encrypted message';
          _lastTime[peerId] = DateTime.now();
          await NotificationService.showIncomingMessage();
        }
        if (mounted) setState(() {});
      },
    );

    // Subscribe to incoming group messages
    _grpChannel = SupabaseBackend.subscribeGroupMessages(
      identityId: id,
      onInsert: (row) async {
        final gid = row['group_id'] as String;
        final auth = context.read<AuthService>();
        final group = auth.group(gid);
        if (group == null) {
          // refresh groups list — maybe we were just added
          await auth.refreshGroups();
          return;
        }
        try {
          final m = await context.read<ChatService>().decryptGroupRow(
                row,
                gid,
                group.createdBy,
              );
          _groupLastMessage[gid] = m.kind == MessageKind.text
              ? m.plaintext
              : 'Attachment: ${m.kind.name}';
          _groupLastTime[gid] = m.createdAt;
        } catch (_) {}
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

    // Subscribe to friend-request updates
    _frUpdateChannel = SupabaseBackend.subscribeFriendRequestUpdates(
      identityId: id,
      onUpdate: (row) async {
        final status = row['status'] as String;
        final otherId = row['to_identity'] as String;
        if (status == 'accepted') {
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

    // One-shot poll for outgoing requests that were accepted while offline
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

  Future<void> _refreshPreviews() async {
    final auth = context.read<AuthService>();
    if (!auth.hasIdentity) return;
    try {
      final inbox = await SupabaseBackend.fetchInbox(null);
      for (final row in inbox) {
        final peerId = row['from_identity'] as String;
        final t = DateTime.parse(row['created_at'] as String).toLocal();
        if (_lastTime[peerId] == null || t.isAfter(_lastTime[peerId]!)) {
          _lastTime[peerId] = t;
          try {
            final m = await context.read<ChatService>().decryptRow(row);
            _lastMessage[peerId] = m.kind == MessageKind.text
                ? m.plaintext
                : 'Attachment: ${m.kind.name}';
          } catch (_) {
            _lastMessage[peerId] = 'Encrypted message';
          }
        }
      }
      // Group previews
      try {
        final gInbox = await SupabaseBackend.fetchGroupInbox(null);
        for (final row in gInbox) {
          final gid = row['group_id'] as String;
          final t = DateTime.parse(row['created_at'] as String).toLocal();
          if (_groupLastTime[gid] == null || t.isAfter(_groupLastTime[gid]!)) {
            _groupLastTime[gid] = t;
            try {
              final group = auth.group(gid);
              if (group != null) {
                final m = await context.read<ChatService>().decryptGroupRow(
                      row,
                      gid,
                      group.createdBy,
                    );
                _groupLastMessage[gid] = m.kind == MessageKind.text
                    ? m.plaintext
                    : 'Attachment: ${m.kind.name}';
              }
            } catch (_) {
              _groupLastMessage[gid] = 'Encrypted group message';
            }
          }
        }
      } catch (_) {}
      if (mounted) setState(() {});
    } catch (_) {}
  }

  @override
  void dispose() {
    _msgChannel?.unsubscribe();
    _grpChannel?.unsubscribe();
    _frChannel?.unsubscribe();
    _frUpdateChannel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final friends = auth.friends;
    final groups = auth.groups;
    final allEmpty = friends.isEmpty && groups.isEmpty;
    return RefreshIndicator(
      key: _refreshKey,
      onRefresh: () async {
        await HapticService.selection();
        await auth.refreshGroups();
        await _refreshPreviews();
      },
      child: allEmpty
          ? ListView(
              children: [
                const SizedBox(height: 80),
                EmptyState(
                  icon: Icons.chat_bubble_outline,
                  title: 'No conversations yet',
                  subtitle:
                      'Open the Friends tab to add someone via their code\nor QR code. All chats are end-to-end encrypted.',
                  actionLabel: 'Add a friend',
                  onAction: () {
                    // Switch to Friends tab via the BottomNavigationBar.
                    // We use a simple navigation: find the home Scaffold and
                    // pop to root, then user taps Friends tab.
                  },
                ),
              ],
            )
          : ListView(
              children: [
                if (groups.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Text('Group chats (${groups.length})',
                        style: Theme.of(context).textTheme.labelMedium),
                  ),
                  for (final g in groups)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.secondary,
                        child: const Icon(Icons.group, color: Colors.white),
                      ),
                      title: Text(g.name),
                      subtitle: Text(
                        _groupLastMessage[g.id] ??
                            '${g.memberIds.length} members',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _groupLastTime[g.id] == null
                          ? null
                          : Text(
                              _formatTime(_groupLastTime[g.id]!),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).hintColor),
                            ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => GroupChatScreen(group: g)),
                      ),
                    ),
                  const Divider(),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Text('Direct chats (${friends.length})',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
                if (friends.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text('No friends yet. Tap the Friends tab.',
                          textAlign: TextAlign.center),
                    ),
                  )
                else
                  for (final f in friends)
                    ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).colorScheme.primary,
                        child: Text(
                          (f.alias?.isNotEmpty ?? false)
                              ? f.alias![0].toUpperCase()
                              : '#',
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      title: Text(f.alias ?? f.identityId.substring(0, 8)),
                      subtitle: Text(
                        _lastMessage[f.identityId] ?? 'Tap to chat',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (_lastTime[f.identityId] != null)
                            Text(
                              _formatTime(_lastTime[f.identityId]!),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Theme.of(context).hintColor),
                            ),
                          if ((_unread[f.identityId] ?? 0) > 0)
                            Container(
                              margin: const EdgeInsets.only(top: 4),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${_unread[f.identityId]}',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                      onTap: () {
                        setState(() => _unread[f.identityId] = 0);
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => ChatScreen(friend: f)),
                        );
                      },
                    ),
              ],
            ),
    );
  }

  String _formatTime(DateTime t) {
    final now = DateTime.now();
    if (t.year == now.year && t.month == now.month && t.day == now.day) {
      return '${t.hour}:${t.minute.toString().padLeft(2, '0')}';
    }
    final diff = now.difference(t);
    if (diff.inDays < 7) {
      return ['Mon','Tue','Wed','Thu','Fri','Sat','Sun'][t.weekday - 1];
    }
    return '${t.day}/${t.month}';
  }
}
