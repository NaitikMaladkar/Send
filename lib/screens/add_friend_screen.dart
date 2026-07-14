import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/friend.dart';
import '../services/auth_service.dart';
import '../services/supabase_backend.dart';

/// Two-pane screen:
///  1. "MyLink" — generate a 24h rotating code to share.
///  2. "Add friend" — paste someone else's code + add an intro.
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});
  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> {
  String? _myCode;
  bool _busy = false;
  final _codeCtrl = TextEditingController();
  final _introCtrl = TextEditingController();
  String? _msg;

  Future<void> _genCode() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final c = await SupabaseBackend.createRotatingCode(null);
      setState(() => _myCode = c);
    } catch (e) {
      setState(() => _msg = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendRequest() async {
    final auth = context.read<AuthService>();
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _msg = 'Paste a code first');
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final resolved = await SupabaseBackend.resolveCode(code);
      await SupabaseBackend.sendFriendRequest(
        resolved.identityId,
        _introCtrl.text.trim().isEmpty ? null : _introCtrl.text.trim(),
      );
      // Cache the friend immediately so the user can start chatting once
      // accepted (or even pre-acceptance, the receiver will see the request).
      // For safety, we still wait for acceptance on the receiver side.
      final friend = Friend(
        identityId: resolved.identityId,
        publicKey: resolved.publicKey.toList(),
        alias: null,
        friendedAt: DateTime.now(),
      );
      await auth.addFriend(friend);
      if (mounted) {
        setState(() {
          _msg = 'Friend request sent. You can chat once they accept.';
          _codeCtrl.clear();
          _introCtrl.clear();
        });
      }
    } catch (e) {
      setState(() => _msg = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add friend')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('My rotating code',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text(
              'Generate a fresh, 24-hour code and share it with the person you '
              'want to talk to. They paste it on their end to send you a friend '
              'request.',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 12),
          if (_myCode == null)
            ElevatedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Generate code'),
              onPressed: _busy ? null : _genCode,
            )
          else
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      _myCode!,
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 1.5),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.copy, size: 18),
                          label: const Text('Copy'),
                          onPressed: () {
                            // Use share_plus for native sheet
                            Share.share('Add me on Send: $_myCode',
                                subject: 'Send invite');
                          },
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('New'),
                          onPressed: _busy ? null : _genCode,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 32),
          const Text('Add a friend',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          const Text('Paste the code they shared with you.',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            decoration: const InputDecoration(labelText: 'Their code'),
            autocorrect: false,
            enableSuggestions: false,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _introCtrl,
            decoration: const InputDecoration(labelText: 'Intro (optional)'),
            maxLength: 200,
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.send),
            label: const Text('Send friend request'),
            onPressed: _busy ? null : _sendRequest,
          ),
          if (_msg != null) ...[
            const SizedBox(height: 16),
            Text(_msg!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.greenAccent, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}
