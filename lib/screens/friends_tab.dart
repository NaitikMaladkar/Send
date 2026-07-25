import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/friend.dart';
import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import '../services/supabase_backend.dart';
import '../widgets/empty_state.dart';
import 'add_friend_screen.dart';
import 'create_group_screen.dart';

/// Lists friends + pending friend requests; tap "+" to add via code or QR.
class FriendsTab extends StatefulWidget {
  const FriendsTab({super.key});
  @override
  State<FriendsTab> createState() => _FriendsTabState();
}

class _FriendsTabState extends State<FriendsTab> {
  Timer? _poll;
  List<Map<String, dynamic>> _pending = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final auth = context.read<AuthService>();
    if (!auth.hasIdentity) return;
    try {
      final rows = await SupabaseBackend.fetchFriendRequests();
      if (mounted) setState(() => _pending = rows);
    } catch (_) {}
  }

  Future<void> _accept(Map<String, dynamic> row) async {
    final auth = context.read<AuthService>();
    final peerId = row['from_identity'] as String;
    final peerName = (row['display_name'] as String?) ?? '';
    try {
      await SupabaseBackend.respondFriendRequest(row['id'] as String, true);
      final pub = await SupabaseBackend.fetchIdentityPublicKey(peerId);
      if (auth.friend(peerId) == null) {
        await auth.addFriend(Friend(
          identityId: peerId,
          publicKey: pub.toList(),
          alias: peerName.isNotEmpty ? peerName : null,
          friendedAt: DateTime.now(),
        ));
      }
      await HapticService.medium();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(peerName.isNotEmpty
                  ? '$peerName added — you can chat now'
                  : 'Friend added — you can chat now')),
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _reject(Map<String, dynamic> row) async {
    try {
      await SupabaseBackend.respondFriendRequest(row['id'] as String, false);
      await _refresh();
    } catch (_) {}
  }

  void _onLongPressFriend(Friend f) async {
    HapticService.longPress();
    final auth = context.read<AuthService>();
    final ctrl = TextEditingController(text: f.alias ?? '');
    await showDialog<void>(
      context: context,
      builder: (_) => SimpleDialog(
        title: Text(f.alias ?? f.identityId.substring(0, 8)),
        children: [
          SimpleDialogOption(
            child: const Text('Edit alias'),
            onPressed: () async {
              Navigator.pop(context);
              final r = await showDialog<String>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('Set alias'),
                  content: TextField(
                    controller: ctrl,
                    decoration: const InputDecoration(hintText: 'e.g. Alice'),
                    maxLength: 50,
                  ),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, null),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () =>
                            Navigator.pop(context, ctrl.text.trim()),
                        child: const Text('Save')),
                  ],
                ),
              );
              if (r != null) {
                await auth.updateFriend(
                    f.copyWith(alias: r.isEmpty ? null : r));
              }
            },
          ),
          SimpleDialogOption(
            child: const Text('Disappearing messages'),
            onPressed: () async {
              Navigator.pop(context);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text(
                        'All messages disappear after 24 hours — no override available.')));
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final friends = auth.friends;
    return Scaffold(
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'fab-group',
            tooltip: 'New group chat',
            onPressed: () {
              if (friends.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Add a friend first to create a group')));
                return;
              }
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const CreateGroupScreen()));
            },
            child: const Icon(Icons.group_add),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.extended(
            heroTag: 'fab-add',
            icon: const Icon(Icons.add),
            label: const Text('Add friend'),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AddFriendScreen())),
          ),
        ],
      ),
      body: friends.isEmpty && _pending.isEmpty
          ? EmptyState(
              icon: Icons.person_add_outlined,
              title: 'No friends yet',
              subtitle:
                  'Share your rotating code or QR code with someone.\nThey paste it on their end to send you a friend request.',
              actionLabel: 'Add a friend',
              onAction: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AddFriendScreen())),
            )
          : ListView(
              children: [
                if (_pending.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text('Incoming requests',
                        style: Theme.of(context).textTheme.labelMedium),
                  ),
                  for (final row in _pending)
                    ListTile(
                      leading: const CircleAvatar(child: Icon(Icons.person)),
                      title: Text(() {
                        final name = row['display_name'] as String?;
                        final pid = row['public_id'];
                        if (name != null && name.isNotEmpty) {
                          return pid != null
                              ? '$name · ID:${(pid is int ? pid : int.tryParse('$pid') ?? 0).toString().padLeft(8, '0')}'
                              : name;
                        }
                        return 'From ${(row['from_identity'] as String).substring(0, 8)}…';
                      }()),
                      subtitle: Text(row['intro'] as String? ?? ''),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.check, color: Colors.green),
                            onPressed: () => _accept(row),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.redAccent),
                            onPressed: () => _reject(row),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                ],
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text('Your friends (${friends.length})',
                      style: Theme.of(context).textTheme.labelMedium),
                ),
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
                    subtitle: Text('ID: ${f.identityId.substring(0, 16)}…',
                        style: const TextStyle(fontSize: 12)),
                    onLongPress: () => _onLongPressFriend(f),
                  ),
              ],
            ),
    );
  }
}
