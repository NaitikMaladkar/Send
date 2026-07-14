import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/keystore.dart';
import 'onboarding_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<IdentityLite> _all = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await SendKeystore.loadIdentities();
    final activeId = await SendKeystore.activeIdentityId();
    setState(() {
      _all = list
          .map((e) => IdentityLite(
              id: e.id, displayCode: e.displayCode, isActive: e.id == activeId))
          .toList();
      _loading = false;
    });
  }

  Future<void> _switchTo(String id) async {
    await context.read<AuthService>().switchTo(id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this identity?'),
        content: const Text(
            'This will erase your private key and friend list from this device. '
            'The server will drop your row within 24 hours. '
            'Messages you sent will remain on recipients\' devices.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    await context.read<AuthService>().deleteActive();
    if (!mounted) return;
    if (!context.read<AuthService>().hasIdentity) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const OnboardingScreen()),
        (_) => false,
      );
    } else {
      _load();
    }
  }

  Future<void> _createNew() async {
    await context.read<AuthService>().createIdentity();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Center(
                  child: CircleAvatar(
                    radius: 48,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: const Icon(Icons.person, size: 56, color: Colors.white),
                  ),
                ),
                const SizedBox(height: 12),
                if (auth.hasIdentity) ...[
                  Center(
                    child: Text('Display code: ${auth.active!.displayCode}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text('Identity: ${auth.active!.id.substring(0, 16)}…',
                        style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                        'Active ${auth.friends.length} friend${auth.friends.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ],
                const SizedBox(height: 24),
                const Text('Identities on this device',
                    style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600)),
                for (final e in _all)
                  ListTile(
                    leading: Icon(e.isActive ? Icons.check_circle : Icons.circle_outlined,
                        color: e.isActive ? Colors.green : Colors.white38),
                    title: Text('#${e.displayCode}'),
                    subtitle: Text(e.id.substring(0, 16)),
                    onTap: e.isActive ? null : () => _switchTo(e.id),
                  ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('Create another identity'),
                  onPressed: _createNew,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                  label: const Text('Delete active identity',
                      style: TextStyle(color: Colors.redAccent)),
                  onPressed: _delete,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
              ],
            ),
    );
  }
}

class IdentityLite {
  final String id;
  final String displayCode;
  final bool isActive;
  const IdentityLite(
      {required this.id, required this.displayCode, required this.isActive});
}
