import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
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
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (e) {
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
              Icon(Icons.enhanced_encryption, size: 80,
                  color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 24),
              const Text('Send',
                  style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text(
                'Anonymous, end-to-end encrypted chat.\n'
                'No phone number. No email. No tracking.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 15),
              ),
              const Spacer(),
              _FeatureRow(icon: Icons.vpn_key, text: 'X25519 + AES-256-GCM encryption'),
              _FeatureRow(icon: Icons.timer, text: 'Rotating shareable codes (24h)'),
              _FeatureRow(icon: Icons.inbox, text: 'Realtime delivery over websocket'),
              _FeatureRow(icon: Icons.auto_delete,
                  text: 'Auto-wipe after 30 days of inactivity'),
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
              const Text(
                'By continuing you agree that this software is provided '
                '"as is" without warranty of any kind.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 12),
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
