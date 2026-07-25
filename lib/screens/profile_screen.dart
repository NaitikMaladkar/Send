import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import '../services/keystore.dart';
import '../utils/constants.dart';
import '../utils/theme.dart';
import 'onboarding_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<_IdentityLite> _all = [];
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
          .map((e) => _IdentityLite(
              id: e.id,
              publicId: e.publicId,
              displayName: e.displayName,
              isActive: e.id == activeId))
          .toList();
      _loading = false;
    });
  }

  Future<void> _switchTo(String id) async {
    await context.read<AuthService>().switchTo(id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _copyId() async {
    final auth = context.read<AuthService>();
    if (auth.active == null) return;
    await Clipboard.setData(ClipboardData(text: auth.active!.displayId));
    await HapticService.light();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied ${auth.active!.displayId}')),
    );
  }

  Future<void> _vanish() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Vanish this account?'),
        content: const Text(
            'This is irreversible. The server will delete:\n\n'
            '• All messages you sent AND received (both sides)\n'
            '• All group messages and memberships\n'
            '• All friend entries (their list loses you too)\n'
            '• All aliases, codes, relay hops\n'
            '• Your identity row (auth token dies)\n\n'
            'Your 4-digit PIN and any local cache will also be wiped from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Vanish forever', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _loading = true);
    await context.read<AuthService>().vanishAccount();
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

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthService>();
    final theme = context.watch<ThemeService>();
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
                    child: Text(auth.active!.displayName,
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(height: 8),
                  // Tap-to-copy ID chip
                  Center(
                    child: InkWell(
                      onTap: _copyId,
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Theme.of(context).colorScheme.primary, width: 1),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.tag,
                                size: 16, color: Theme.of(context).colorScheme.primary),
                            const SizedBox(width: 4),
                            Text(auth.active!.displayId,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                  color: Theme.of(context).colorScheme.primary,
                                )),
                            const SizedBox(width: 6),
                            const Icon(Icons.copy, size: 14, color: Colors.grey),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Center(
                    child: Text('Tap ID to copy · shown only on this screen',
                        style: const TextStyle(color: Colors.grey, fontSize: 11)),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                        'Active ${auth.friends.length} friend${auth.friends.length == 1 ? '' : 's'} · '
                        '${auth.groups.length} group${auth.groups.length == 1 ? '' : 's'}',
                        style: const TextStyle(color: Colors.white70)),
                  ),
                ],
                const SizedBox(height: 24),

                // ---------- Privacy ----------
                _SectionHeader('Privacy'),
                ListTile(
                  leading: const Icon(Icons.timer),
                  title: const Text('Disappearing messages'),
                  subtitle: const Text(
                      'Fixed at 24 hours · cannot be turned off or overridden'),
                  trailing: const Icon(Icons.lock, size: 18, color: Colors.grey),
                  enabled: false,
                  onTap: () {},
                ),
                SwitchListTile(
                  secondary: const Icon(Icons.visibility),
                  title: const Text('Read receipts'),
                  subtitle: Text(
                    auth.readReceipts
                        ? 'On — you and your friends see when messages are read'
                        : 'Off — you also won\'t see others\' read receipts',
                  ),
                  value: auth.readReceipts,
                  onChanged: (v) async {
                    await auth.setReadReceipts(v);
                    await HapticService.selection();
                  },
                ),
                const Divider(),

                // ---------- Appearance ----------
                _SectionHeader('Appearance'),
                ListTile(
                  leading: const Icon(Icons.palette),
                  title: const Text('Theme'),
                  trailing: DropdownButton<AppThemeMode>(
                    value: theme.mode,
                    items: const [
                      DropdownMenuItem(
                          value: AppThemeMode.system, child: Text('System')),
                      DropdownMenuItem(
                          value: AppThemeMode.light, child: Text('Light')),
                      DropdownMenuItem(
                          value: AppThemeMode.dark, child: Text('Dark')),
                    ],
                    onChanged: (m) async {
                      if (m != null) await theme.setMode(m);
                    },
                  ),
                ),
                const Divider(),

                // ---------- Identities on this device ----------
                _SectionHeader('Identities on this device'),
                for (final e in _all)
                  ListTile(
                    leading: Icon(e.isActive ? Icons.check_circle : Icons.circle_outlined,
                        color: e.isActive ? Colors.green : Colors.grey),
                    title: Text(e.displayName.isEmpty ? e.displayId : e.displayName),
                    subtitle: Text('${e.displayId} · ${e.id.substring(0, 8)}…'),
                    onTap: e.isActive ? null : () => _switchTo(e.id),
                  ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout, color: Colors.redAccent),
                  label: const Text('Vanish account (delete everywhere)',
                      style: TextStyle(color: Colors.redAccent)),
                  onPressed: _vanish,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.redAccent),
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 32),
                const Center(
                  child: Text('Send v1.0 · Anonymous E2EE Chat',
                      style: TextStyle(color: Colors.grey, fontSize: 12)),
                ),
              ],
            ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
      child: Text(text,
          style: TextStyle(
              color: Theme.of(context).colorScheme.secondary,
              fontWeight: FontWeight.w600,
              fontSize: 13)),
    );
  }
}

class _IdentityLite {
  final String id;
  final int publicId;
  final String displayName;
  final bool isActive;
  const _IdentityLite({
    required this.id,
    required this.publicId,
    required this.displayName,
    required this.isActive,
  });

  String get displayId => 'ID:${publicId.toString().padLeft(8, '0')}';
}
