import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/friend.dart';
import '../services/auth_service.dart';
import '../services/supabase_backend.dart';
import 'add_friend_screen.dart';

/// Lists friends + pending friend requests; tap "+" to add via code.
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
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
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
    try {
      await SupabaseBackend.respondFriendRequest(row['id'] as String, true);
      // Fetch peer's public key so we can encrypt messages to them.
      final pub = await SupabaseBackend.fetchIdentityPublicKey(peerId);
      // Skip if already added (idempotent)
      if (auth.friend(peerId) == null) {
        await auth.addFriend(Friend(
          identityId: peerId,
          publicKey: pub.toList(),
          alias: null,
          friendedAt: DateTime.now(),
        ));
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Friend added — you can chat now')),
        );
      }
      await _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed: $e')));
      }
    }
  }

  Future<void> _reject(Map<String, dynamic> row) async {
    try {
      await SupabaseBackend.respondFriendRequest(
          row['id'] as String, false);
      await _refresh();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final friends = auth.friends;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add friend'),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AddFriendScreen())),
      ),
      body: ListView(
        children: [
          if (_pending.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('Incoming requests',
                  style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
            ),
            for (final row in _pending)
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.person)),
                title: Text('From ${(row['from_identity'] as String).substring(0, 8)}…'),
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
                style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
          ),
          if (friends.isEmpty)
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text('No friends yet. Tap "Add friend" to share your code.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38)),
              ),
            )
          else
            for (final f in friends)
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  child: Text(
                    (f.alias?.isNotEmpty ?? false) ? f.alias![0].toUpperCase() : '#',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
                title: Text(f.alias ?? f.identityId.substring(0, 8)),
                subtitle: Text('ID: ${f.identityId.substring(0, 16)}…',
                    style: const TextStyle(fontSize: 12, color: Colors.white38)),
              ),
        ],
      ),
    );
  }
}
