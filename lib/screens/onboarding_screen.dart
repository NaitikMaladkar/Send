import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/haptic_service.dart';
import 'home_screen.dart';

/// First-run flow: explains what Send is, generates a fresh anonymous identity.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _busy = false;
  String? _err;

  Future<void> _create() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await context.read<AuthService>().createIdentity();
      await HapticService.medium();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
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
          child: Column(
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
              _FeatureRow(icon: Icons.timer, text: 'Disappearing messages (1h–30d)'),
              _FeatureRow(icon: Icons.qr_code, text: 'QR codes for friend-add'),
              _FeatureRow(icon: Icons.mic, text: 'Voice messages up to 25 min'),
              _FeatureRow(icon: Icons.group, text: 'Group chats (up to 100)'),
              _FeatureRow(icon: Icons.alt_route, text: 'Onion-routed delivery'),
              _FeatureRow(icon: Icons.screenshot, text: 'Screenshot self-destruct'),
              _FeatureRow(icon: Icons.palette, text: 'Dark / light theme'),
              const Spacer(),
              if (_err != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_err!,
                      style: const TextStyle(color: Colors.redAccent),
                      textAlign: TextAlign.center),
                ),
              ElevatedButton(
                onPressed: _busy ? null : _create,
                child: _busy
                    ? const SizedBox(
                        height: 24, width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create my anonymous identity'),
              ),
              const SizedBox(height: 8),
              Text(
                'By continuing you agree that this software is provided '
                '"as is" without warranty of any kind.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).hintColor, fontSize: 12),
              ),
            ],
          ),
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
