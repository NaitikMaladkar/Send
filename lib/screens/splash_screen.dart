import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/keystore.dart';
import 'onboarding_screen.dart';
import 'home_screen.dart';
import 'pin_screen.dart';

/// Cold-start router.
///
/// Flow:
///   1. AuthService.init() — load any saved identity from secure storage.
///   2. If no identity → OnboardingScreen (signup/signin landing).
///   3. If identity exists AND a PIN is set → PinScreen (unlock mode).
///      The PIN flag is in-session: once unlocked, the user can navigate
///      freely within the app until the process dies.
///   4. If identity exists but no PIN (edge case: upgraded from v1.0) →
///      PinScreen (setup mode) so the user picks a PIN.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    final auth = context.read<AuthService>();
    await auth.init();
    if (!mounted) return;

    Widget next;
    if (!auth.hasIdentity) {
      next = const OnboardingScreen();
    } else if (auth.pinUnlocked) {
      // Already unlocked this session — go straight to home.
      next = const HomeScreen();
    } else {
      final hasPin = await SendKeystore.hasPin();
      next = PinScreen(mode: hasPin ? PinMode.unlock : PinMode.setup);
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => next),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bolt, size: 80, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            const Text('Send',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text('Anonymous · End-to-end encrypted',
                style: TextStyle(color: Theme.of(context).hintColor)),
            const SizedBox(height: 24),
            const CircularProgressIndicator(strokeWidth: 2),
          ],
        ),
      ),
    );
  }
}
