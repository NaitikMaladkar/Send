import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import '../services/supabase_backend.dart';
import '../utils/constants.dart';
import '../widgets/empty_state.dart';

class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});
  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtrl = TextEditingController();
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a group name')));
      return;
    }
    if (_selected.length < GroupConfig.minMembers) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Select at least ${GroupConfig.minMembers} friend')));
      return;
    }
    if (_selected.length > GroupConfig.maxMembers) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Max ${GroupConfig.maxMembers} members')));
      return;
    }
    setState(() => _busy = true);
    try {
      final auth = context.read<AuthService>();
      final memberIds = _selected.toList();
      // Creator is auto-added by the RPC.
      final gid = await SupabaseBackend.createGroup(name, memberIds);
      // Refresh groups cache
      await auth.refreshGroups();
      await HapticService.medium();
      if (mounted) {
        Navigator.pop(context, gid);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final friends = auth.friends;
    return Scaffold(
      appBar: AppBar(
        title: const Text('New group'),
        actions: [
          TextButton(
            onPressed: _busy ? null : _create,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'e.g. Weekend trip',
              ),
              maxLength: 80,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text('Members: ${_selected.length}/${GroupConfig.maxMembers}',
                    style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (friends.isEmpty)
            const Expanded(
              child: EmptyState(
                icon: Icons.person_add_outlined,
                title: 'No friends yet',
                subtitle: 'Add at least one friend before creating a group.',
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: friends.length,
                itemBuilder: (context, i) {
                  final f = friends[i];
                  final selected = _selected.contains(f.identityId);
                  return ListTile(
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
                    trailing: Checkbox(
                      value: selected,
                      onChanged: (v) {
                        setState(() {
                          if (v == true) {
                            if (_selected.length >= GroupConfig.maxMembers) {
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                  content: Text(
                                      'Max ${GroupConfig.maxMembers} members')));
                              return;
                            }
                            _selected.add(f.identityId);
                          } else {
                            _selected.remove(f.identityId);
                          }
                        });
                      },
                    ),
                    onTap: () {
                      setState(() {
                        if (selected) {
                          _selected.remove(f.identityId);
                        } else if (_selected.length < GroupConfig.maxMembers) {
                          _selected.add(f.identityId);
                        }
                      });
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
