import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import '../services/keystore.dart';
import 'home_screen.dart';
import 'onboarding_screen.dart';

/// 4-digit app PIN gate. Two modes:
///   - Mode.setup    : no PIN set yet → ask user to enter + confirm a new PIN
///   - Mode.unlock   : PIN already set → ask user to enter existing PIN
///
/// On successful unlock/setup, the app routes to HomeScreen (if user has an
/// identity) or OnboardingScreen (fresh install / after vanish).
class PinScreen extends StatefulWidget {
  final PinMode mode;
  const PinScreen({super.key, required this.mode});

  @override
  State<PinScreen> createState() => _PinScreenState();
}

enum PinMode { setup, unlock }

class _PinScreenState extends State<PinScreen> {
  String _entered = '';
  String? _firstEntered; // for setup confirmation
  String? _err;
  bool _busy = false;

  static const int _len = 4;

  Future<void> _onKey(String digit) async {
    if (_busy || _entered.length >= _len) return;
    setState(() {
      _entered += digit;
      _err = null;
    });
    await HapticService.light();
    if (_entered.length == _len) {
      await _submit();
    }
  }

  Future<void> _onDelete() async {
    if (_entered.isEmpty) return;
    setState(() {
      _entered = _entered.substring(0, _entered.length - 1);
      _err = null;
    });
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      if (widget.mode == PinMode.setup) {
        if (_firstEntered == null) {
          // First entry — stash and ask to confirm.
          await Future.delayed(const Duration(milliseconds: 150));
          setState(() {
            _firstEntered = _entered;
            _entered = '';
            _busy = false;
          });
          return;
        }
        if (_entered != _firstEntered) {
          await HapticService.error();
          setState(() {
            _err = 'PINs did not match. Try again.';
            _entered = '';
            _firstEntered = null;
            _busy = false;
          });
          return;
        }
        // Match — save PIN, mark unlocked, route onward.
        await SendKeystore.savePin(_entered);
        await HapticService.medium();
        if (!mounted) return;
        context.read<AuthService>().markPinUnlocked();
        _routeOnward();
        return;
      }

      // Unlock mode — verify against stored PIN.
      final stored = await SendKeystore.loadPin();
      if (stored == null) {
        // PIN was cleared (e.g. after vanish) — route onward; setup will
        // happen next launch if the user creates a new identity.
        if (!mounted) return;
        context.read<AuthService>().markPinUnlocked();
        _routeOnward();
        return;
      }
      if (_entered != stored) {
        await HapticService.error();
        setState(() {
          _err = 'Wrong PIN. Try again.';
          _entered = '';
          _busy = false;
        });
        return;
      }
      await HapticService.medium();
      if (!mounted) return;
      context.read<AuthService>().markPinUnlocked();
      _routeOnward();
    } catch (e) {
      await HapticService.error();
      setState(() {
        _err = '$e';
        _entered = '';
        _firstEntered = null;
        _busy = false;
      });
    }
  }

  void _routeOnward() {
    final auth = context.read<AuthService>();
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) =>
            auth.hasIdentity ? const HomeScreen() : const OnboardingScreen(),
      ),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isConfirming =
        widget.mode == PinMode.setup && _firstEntered != null;
    final title = widget.mode == PinMode.setup
        ? (isConfirming ? 'Confirm your PIN' : 'Set a 4-digit PIN')
        : 'Enter your PIN';
    final subtitle = widget.mode == PinMode.setup
        ? (isConfirming
            ? 'Re-enter to confirm'
            : 'Required to unlock Send each time you open the app.')
        : 'Required to unlock Send.';

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 2),
            Icon(Icons.lock_outline,
                size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13)),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_len, (i) {
                final filled = i < _entered.length;
                return Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled
                        ? Theme.of(context).colorScheme.primary
                        : Colors.transparent,
                    border: Border.all(
                        color: Theme.of(context).colorScheme.primary, width: 2),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
            if (_err != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: Text(_err!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            const Spacer(flex: 1),
            _numpad(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _numpad() {
    return Column(
      children: [
        for (final row in [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final d in row) _numpadKey(d),
                // Bottom-left is empty, bottom-right is backspace.
                if (row == ['7', '8', '9']) ...[
                  const SizedBox(width: 72),
                  _backspaceKey(),
                ] else
                  const SizedBox(width: 72),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(width: 72),
              _numpadKey('0'),
              const SizedBox(width: 72),
            ],
          ),
        ),
      ],
    );
  }

  Widget _numpadKey(String d) {
    return Container(
      width: 72,
      height: 72,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      child: OutlinedButton(
        onPressed: _busy ? null : () => _onKey(d),
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: Text(d,
            style:
                const TextStyle(fontSize: 26, fontWeight: FontWeight.w400)),
      ),
    );
  }

  Widget _backspaceKey() {
    return Container(
      width: 72,
      height: 72,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      child: OutlinedButton(
        onPressed: _busy || _entered.isEmpty ? null : _onDelete,
        style: OutlinedButton.styleFrom(
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
        ),
        child: const Icon(Icons.backspace_outlined, size: 24),
      ),
    );
  }
}
