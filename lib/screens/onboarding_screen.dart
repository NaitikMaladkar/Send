import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/auth_service.dart';
import '../services/crypto.dart';
import '../services/haptic_service.dart';
import '../services/keystore.dart';
import '../utils/constants.dart';
import 'home_screen.dart';
import 'pin_screen.dart';

/// TextInputFormatter that limits to lowercase a-z0-9 and 8 chars.
class _PasskeyFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final s = newValue.text.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'), '');
    final truncated = s.length > 8 ? s.substring(0, 8) : s;
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}

/// TextInputFormatter that allows only digits with a max length.
class _DigitsOnlyFormatter extends TextInputFormatter {
  final int maxLength;
  _DigitsOnlyFormatter(this.maxLength);
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final s = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    final truncated = s.length > maxLength ? s.substring(0, maxLength) : s;
    return TextEditingValue(
      text: truncated,
      selection: TextSelection.collapsed(offset: truncated.length),
    );
  }
}

/// First-run / logged-out landing screen. Replaces the old "Create my
/// anonymous identity" onboarding entirely.
///
/// Two flows:
///   1. Sign up — pick a display name + 8-char passkey → server assigns an
///      8-digit ID (ID:00000001, ...). The X25519 private key is encrypted
///      with the passkey (PBKDF2 + AES-GCM) and uploaded to the server for
///      re-login. After signup, the user sets a 4-digit app PIN.
///   2. Already a Sender — enter ID + passkey to sign in. Server returns
///      the encrypted private key blob; we decrypt locally.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

enum _Mode { landing, signup, signin }

class _OnboardingScreenState extends State<OnboardingScreen> {
  _Mode _mode = _Mode.landing;
  bool _busy = false;
  String? _err;

  // signup form state
  final _signupDisplayName = TextEditingController();
  final _signupPasskey = TextEditingController();
  bool _signupPasskeyVisible = false;

  // signin form state
  final _signinId = TextEditingController();
  final _signinPasskey = TextEditingController();
  bool _signinPasskeyVisible = false;

  @override
  void dispose() {
    _signupDisplayName.dispose();
    _signupPasskey.dispose();
    _signinId.dispose();
    _signinPasskey.dispose();
    super.dispose();
  }

  // ============================================================
  //  Landing — choose Sign up or Already a Sender?
  // ============================================================

  Widget _buildLanding() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        Icon(Icons.bolt, size: 80,
            color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 24),
        const Text('Send',
            style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
            textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Anonymous, end-to-end encrypted chat.\n'
          'No phone number. No email. No tracking.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: Theme.of(context).hintColor, fontSize: 15),
        ),
        const Spacer(),
        _FeatureRow(icon: Icons.vpn_key, text: 'X25519 + AES-256-GCM encryption'),
        _FeatureRow(icon: Icons.timer, text: 'Messages disappear in 24 hours'),
        _FeatureRow(icon: Icons.qr_code, text: 'QR codes for friend-add (25-min rotating)'),
        _FeatureRow(icon: Icons.mic, text: 'Voice messages up to 25 min'),
        _FeatureRow(icon: Icons.group, text: 'Group chats (up to 100)'),
        _FeatureRow(icon: Icons.alt_route, text: 'Onion-routed delivery'),
        _FeatureRow(icon: Icons.lock, text: '4-digit app PIN'),
        const Spacer(),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_err!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center),
          ),
        ElevatedButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _mode = _Mode.signup;
                    _err = null;
                  }),
          child: const Text('Create account'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _mode = _Mode.signin;
                    _err = null;
                  }),
          child: const Text('Already a Sender? Sign in'),
        ),
        const SizedBox(height: 8),
        Text(
          'By continuing you agree that this software is provided '
          '"as is" without warranty of any kind.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
        ),
      ],
    );
  }

  // ============================================================
  //  Sign up
  // ============================================================

  Widget _buildSignup() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _mode = _Mode.landing;
                        _err = null;
                      }),
            ),
            const Expanded(
              child: Text('Create your account',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
            ),
            const SizedBox(width: 48),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _signupDisplayName,
          decoration: const InputDecoration(
            labelText: 'Display name',
            hintText: 'Anything you like (not unique)',
            prefixIcon: Icon(Icons.person_outline),
          ),
          maxLength: 50,
          textCapitalization: TextCapitalization.words,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _signupPasskey,
          decoration: InputDecoration(
            labelText: 'Passkey (8 chars, a-z 0-9)',
            prefixIcon: const Icon(Icons.password_outlined),
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Generate random',
                  icon: const Icon(Icons.casino_outlined, size: 20),
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _signupPasskey.text =
                                SendCrypto.generateRandomPasskey();
                          });
                        },
                ),
                IconButton(
                  tooltip: _signupPasskeyVisible ? 'Hide' : 'Show',
                  icon: Icon(
                    _signupPasskeyVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  onPressed: () => setState(() =>
                      _signupPasskeyVisible = !_signupPasskeyVisible),
                ),
              ],
            ),
          ),
          obscureText: !_signupPasskeyVisible,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [_PasskeyFormatter()],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text('How this works',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              SizedBox(height: 6),
              Text(
                '• Your passkey encrypts your private key on this device.\n'
                '• The encrypted key is uploaded so you can sign in after reinstall.\n'
                '• There is NO recovery — lose the passkey, lose the account.\n'
                '• Your 8-digit ID (e.g. ID:00000001) is shown on your profile.',
                style: TextStyle(fontSize: 12, height: 1.5),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_err!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center),
          ),
        ElevatedButton(
          onPressed: _busy ? null : _doSignup,
          child: _busy
              ? const SizedBox(
                  height: 24, width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Create account'),
        ),
      ],
    );
  }

  Future<void> _doSignup() async {
    final name = _signupDisplayName.text.trim();
    final passkey = _signupPasskey.text.trim().toLowerCase();
    if (name.isEmpty) {
      setState(() => _err = 'Pick a display name');
      return;
    }
    if (!RegExp(PasskeyConfig.pattern).hasMatch(passkey)) {
      setState(() => _err = 'Passkey must be exactly 8 chars (a-z 0-9)');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await context.read<AuthService>().signUp(
            displayName: name,
            passkey: passkey,
          );
      await HapticService.medium();
      if (!mounted) return;
      // After signup, route to PIN setup.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const PinScreen(mode: PinMode.setup)),
      );
    } catch (e) {
      await HapticService.error();
      setState(() {
        _err = '$e';
        _busy = false;
      });
    }
  }

  // ============================================================
  //  Sign in
  // ============================================================

  Widget _buildSignin() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 16),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _mode = _Mode.landing;
                        _err = null;
                      }),
            ),
            const Expanded(
              child: Text('Sign in',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  textAlign: TextAlign.center),
            ),
            const SizedBox(width: 48),
          ],
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _signinId,
          decoration: const InputDecoration(
            labelText: 'Your ID',
            hintText: 'e.g. 00000001',
            prefixIcon: Icon(Icons.tag),
          ),
          keyboardType: TextInputType.number,
          inputFormatters: [_DigitsOnlyFormatter(8)],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _signinPasskey,
          decoration: InputDecoration(
            labelText: 'Passkey (8 chars, a-z 0-9)',
            prefixIcon: const Icon(Icons.password_outlined),
            suffixIcon: IconButton(
              tooltip: _signinPasskeyVisible ? 'Hide' : 'Show',
              icon: Icon(
                _signinPasskeyVisible
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 20,
              ),
              onPressed: () => setState(() =>
                  _signinPasskeyVisible = !_signinPasskeyVisible),
            ),
          ),
          obscureText: !_signinPasskeyVisible,
          autocorrect: false,
          enableSuggestions: false,
          inputFormatters: [_PasskeyFormatter()],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Text(
            'If you forgot your passkey, your account cannot be recovered. '
            'You will need to create a new account.',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        const Spacer(),
        if (_err != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_err!,
                style: const TextStyle(color: Colors.redAccent),
                textAlign: TextAlign.center),
          ),
        ElevatedButton(
          onPressed: _busy ? null : _doSignin,
          child: _busy
              ? const SizedBox(
                  height: 24, width: 24,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text('Sign in'),
        ),
      ],
    );
  }

  Future<void> _doSignin() async {
    final idStr = _signinId.text.trim();
    final passkey = _signinPasskey.text.trim().toLowerCase();
    if (!RegExp(r'^[0-9]{1,8}$').hasMatch(idStr)) {
      setState(() => _err = 'Enter your 8-digit ID');
      return;
    }
    if (!RegExp(PasskeyConfig.pattern).hasMatch(passkey)) {
      setState(() => _err = 'Passkey must be exactly 8 chars (a-z 0-9)');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await context.read<AuthService>().signIn(
            publicId: int.parse(idStr),
            passkey: passkey,
          );
      await HapticService.medium();
      if (!mounted) return;
      // Signed in — route to PIN setup (the account was just created on
      // this device, so no PIN exists yet).
      final hasPin = await SendKeystore.hasPin();
      if (!mounted) return;
      if (hasPin) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      } else {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const PinScreen(mode: PinMode.setup)),
        );
      }
    } catch (e) {
      await HapticService.error();
      setState(() {
        _err = '$e';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: switch (_mode) {
            _Mode.landing => _buildLanding(),
            _Mode.signup => _buildSignup(),
            _Mode.signin => _buildSignin(),
          },
        ),
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _FeatureRow({required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.secondary, size: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }
}
