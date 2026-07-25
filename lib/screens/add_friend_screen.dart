import 'dart:async';

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
///  1. "MyLink" — generate a 25-min rotating code + QR code to share.
///  2. "Add friend" — paste someone else's code OR scan their QR.
class AddFriendScreen extends StatefulWidget {
  const AddFriendScreen({super.key});
  @override
  State<AddFriendScreen> createState() => _AddFriendScreenState();
}

class _AddFriendScreenState extends State<AddFriendScreen> with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this, initialIndex: 0);
  late final MobileScannerController _scannerController = MobileScannerController();
  String? _myCode;
  bool _busy = false;
  final _codeCtrl = TextEditingController();
  final _introCtrl = TextEditingController();

  /// Last status message shown to the user. Null = hidden.
  String? _msg;

  /// Severity of the last message — controls colour (green for success,
  /// red for error). Without this, "Failed: ..." appeared in green which
  /// was confusing.
  bool _isError = false;

  /// Guard against the scanner firing onDetect multiple times for the same
  /// code while we're already processing it. MobileScanner can fire several
  /// times per second while the QR is in view; without this guard every
  /// extra detection kicked off a new RPC, racing against the first one
  /// and producing the flickering "Failed" toast.
  String? _lastScannedCode;
  bool _scannerPaused = false;

  /// When our rotating code was generated (for countdown display + auto-expiry).
  DateTime? _codeGeneratedAt;

  /// Auto-expiry timer — fires at the 25-min mark to clear the stale code.
  Timer? _expiryTimer;

  /// 1-second ticker for the live countdown display.
  Timer? _countdownTimer;

  @override
  void dispose() {
    _tab.dispose();
    _codeCtrl.dispose();
    _introCtrl.dispose();
    _scannerController.dispose();
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startExpiryTimer() {
    _expiryTimer?.cancel();
    _countdownTimer?.cancel();
    if (_codeGeneratedAt == null) return;
    final expiry = _codeGeneratedAt!.add(const Duration(minutes: 25));
    _expiryTimer = Timer(expiry.difference(DateTime.now()), () {
      if (!mounted) return;
      setState(() {
        _myCode = null;
        _codeGeneratedAt = null;
        _msg = 'Code expired. Tap "Generate" for a fresh one.';
        _isError = false;
      });
    });
    // 1-second countdown refresh
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  String? get _remainingLabel {
    if (_codeGeneratedAt == null || _myCode == null) return null;
    final expiry = _codeGeneratedAt!.add(const Duration(minutes: 25));
    final remaining = expiry.difference(DateTime.now());
    if (remaining.isNegative) return 'expired';
    final m = remaining.inMinutes;
    final s = remaining.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }


  Future<void> _genCode() async {
    setState(() {
      _busy = true;
      _msg = null;
      _isError = false;
    });
    try {
      final c = await SupabaseBackend.createRotatingCode(null);
      _codeGeneratedAt = DateTime.now();
      setState(() {
        _myCode = c;
        _msg = 'Code generated — valid for 25 minutes (one-shot).';
        _isError = false;
      });
      _startExpiryTimer();
      await HapticService.light();
    } catch (e) {
      setState(() {
        _msg = 'Failed: $e';
        _isError = true;
      });
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _sendRequest(String code) async {
    final auth = context.read<AuthService>();
    if (code.isEmpty) {
      setState(() {
        _msg = 'Paste or scan a code first';
        _isError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _msg = null;
      _isError = false;
    });
    try {
      final resolved = await SupabaseBackend.resolveCode(code);

      // Don't allow adding yourself.
      if (auth.active != null && resolved.identityId == auth.active!.id) {
        setState(() {
          _msg = "That's your own code — share it with a friend instead.";
          _isError = true;
        });
        return;
      }

      // Already a friend? Skip the request.
      if (auth.friend(resolved.identityId) != null) {
        setState(() {
          _msg = 'You are already friends with this person.';
          _isError = false;
        });
        return;
      }

      await SupabaseBackend.sendFriendRequest(
        resolved.identityId,
        _introCtrl.text.trim().isEmpty ? null : _introCtrl.text.trim(),
      );
      final friend = Friend(
        identityId: resolved.identityId,
        publicKey: resolved.publicKey.toList(),
        alias: resolved.displayName.isNotEmpty ? resolved.displayName : null,
        friendedAt: DateTime.now(),
      );
      await auth.addFriend(friend);
      await HapticService.medium();
      if (mounted) {
        setState(() {
          _msg = resolved.displayName.isNotEmpty
              ? 'Friend request sent to ${resolved.displayName}. You can chat once they accept.'
              : 'Friend request sent. You can chat once they accept.';
          _isError = false;
          _codeCtrl.clear();
          _introCtrl.clear();
        });
      }
    } catch (e) {
      await HapticService.error();
      if (mounted) {
        setState(() {
          _msg = 'Failed: $e';
          _isError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Called by MobileScanner when a barcode is detected. MobileScanner can
  /// fire this multiple times per second while the QR is in view, so we
  /// de-duplicate by code value and pause scanning for 1.5s after each
  /// detection to let the in-flight request complete.
  void _onDetect(BarcodeCapture capture) {
    if (_busy || _scannerPaused) return;
    final val = capture.barcodes.firstOrNull?.rawValue;
    if (val == null || val.isEmpty) return;
    var code = val;
    if (code.startsWith('send:')) code = code.substring(5);
    if (code == _lastScannedCode) return;
    _lastScannedCode = code;
    _codeCtrl.text = code;
    // Pause scanner briefly to prevent re-entry during RPC.
    _scannerPaused = true;
    _scannerController.stop();
    _sendRequest(code).whenComplete(() {
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && _tab.index == 1) {
          _scannerPaused = false;
          _scannerController.start();
        }
      });
    });
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
            'Generate a fresh, 25-minute code and share it with the person you '
            'want to talk to. They paste it on their end — or scan the QR — '
            'to send you a friend request. The code is one-shot: once they '
            'scan it, you\'ll need a new one for the next person.',
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
                  if (_remainingLabel != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.timer_outlined, size: 16, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text('Expires in $_remainingLabel',
                              style: const TextStyle(color: Colors.grey, fontSize: 13)),
                        ],
                      ),
                    ),
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
        if (_msg != null && _tab.index == 0) ...[
          const SizedBox(height: 16),
          Text(
            _msg!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _isError ? Colors.redAccent : Colors.greenAccent,
              fontSize: 13,
            ),
          ),
        ],
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
              controller: _scannerController,
              onDetect: _onDetect,
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
          icon: _busy
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.send),
          label: Text(_busy ? 'Sending…' : 'Send friend request'),
          onPressed: _busy
              ? null
              : () => _sendRequest(_codeCtrl.text.trim()),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 16),
          Text(
            _msg!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _isError ? Colors.redAccent : Colors.greenAccent,
              fontSize: 13,
            ),
          ),
        ],
      ],
    );
  }
}
