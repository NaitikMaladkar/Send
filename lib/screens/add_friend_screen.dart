import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../models/friend.dart';
import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import '../services/supabase_backend.dart';

/// Two-pane screen:
///  1. "MyLink" — generate a 24h rotating code + QR code to share.
///  2. "Add friend" — paste someone else's code OR scan their QR.
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});
  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this, initialIndex: 0);
  String? _myCode;
  bool _busy = false;
  final _codeCtrl = TextEditingController();
  final _introCtrl = TextEditingController();
  String? _msg;

  @override
  void dispose() {
    _tab.dispose();
    _codeCtrl.dispose();
    _introCtrl.dispose();
    super.dispose();
  }

  Future<void> _genCode() async {
    setState(() {
      _busy = true;
      _msg = null;
    });
    try {
      final c = await SupabaseBackend.createRotatingCode(null);
      setState(() => _myCode = c);
      await HapticService.light();
    } catch (e) {
      setState(() => _msg = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendRequest(String code) async {
    final auth = context.read<AuthService>();
    if (code.isEmpty) {
      setState(() => _msg = 'Paste or scan a code first');
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
      final friend = Friend(
        identityId: resolved.identityId,
        publicKey: resolved.publicKey.toList(),
        alias: null,
        friendedAt: DateTime.now(),
      );
      await auth.addFriend(friend);
      await HapticService.medium();
      if (mounted) {
        setState(() {
          _msg = 'Friend request sent. You can chat once they accept.';
          _codeCtrl.clear();
          _introCtrl.clear();
        });
      }
    } catch (e) {
      await HapticService.error();
      setState(() => _msg = 'Failed: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add friend'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [
            Tab(icon: Icon(Icons.qr_code), text: 'My QR'),
            Tab(icon: Icon(Icons.person_add), text: 'Add'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildMyCodeTab(),
          _buildAddTab(),
        ],
      ),
    );
  }

  Widget _buildMyCodeTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('My rotating code',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(
            'Generate a fresh, 24-hour code and share it with the person you '
            'want to talk to. They paste it on their end — or scan the QR — '
            'to send you a friend request.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 20),
        if (_myCode == null)
          ElevatedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Generate code + QR'),
            onPressed: _busy ? null : _genCode,
          )
        else
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: QrImageView(
                        data: 'send:$_myCode',
                        version: QrVersions.auto,
                        size: 220,
                        backgroundColor: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
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
                        label: const Text('Share'),
                        onPressed: () {
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
      ],
    );
  }

  Widget _buildAddTab() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Scan their QR code',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text('Point your camera at their QR code.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
        const SizedBox(height: 12),
        SizedBox(
          height: 240,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: MobileScanner(
              onDetect: (capture) {
                final val = capture.barcodes.firstOrNull?.rawValue;
                if (val != null) {
                  var code = val;
                  if (code.startsWith('send:')) code = code.substring(5);
                  _codeCtrl.text = code;
                  _sendRequest(code);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Text('Or paste the code',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
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
          onPressed: _busy
              ? null
              : () => _sendRequest(_codeCtrl.text.trim()),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 16),
          Text(_msg!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 13)),
        ],
      ],
    );
  }
}
