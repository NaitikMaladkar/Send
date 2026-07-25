/// Send — public Supabase config.
///
/// These values are intentionally committed to the repo. The anon key is
/// designed to be embedded in client apps — Row Level Security on every
/// table ensures it cannot read or write data without a valid per-identity
/// auth token issued by `signup()` / `signin()`.
class SupabaseConfig {
  static const String url = 'https://xtpsvneqdsaiqtqxakhu.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inh0'
      'cHN2bmVxZHNhaXF0cXhha2h1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM4NTkwOTMsImV4'
      'cCI6MjA5OTQzNTA5M30.7SqykFJu3YM7ofibeOj2U21fOvMV-LpB1IDBAz6jsDg';

  static const String storageBucket = 'attachments';
  static const int imageMaxBytes = 10 * 1024 * 1024; // 10 MB
  static const int pdfMaxBytes = 25 * 1024 * 1024;   // 25 MB
}

/// Inactivity window before server-side cron deletes the identity.
class InactivityConfig {
  static const Duration warnAfter = Duration(days: 25);
  static const Duration deleteAfter = Duration(days: 30);
}

/// Disappearing-messages configuration.
///
/// Messages ALWAYS disappear after exactly 24 hours — there is no override.
/// This is enforced server-side by a CHECK constraint on the messages and
/// group_messages tables (`ttl_seconds = 86400`), and the trigger
/// `compute_expires_at` sets `expires_at = created_at + interval '24 hours'`.
/// A `sweep_expired_messages` cron hard-deletes rows past their expiry.
class DisappearingConfig {
  static const int seconds = 86400; // 24 hours, fixed
}

/// Rotating friend-add code configuration.
class RotatingCodeConfig {
  /// Code validity window. The code auto-expires after this duration.
  static const Duration validity = Duration(minutes: 25);

  /// Code is one-shot: after a successful `resolve_code`, the code is
  /// marked used and any subsequent attempt raises 'code already used'.
  /// The creator's app must call `create_rotating_code` again to refresh
  /// for the next share.
  static const bool oneShot = true;
}

/// Voice-message configuration.
class VoiceConfig {
  static const Duration maxDuration = Duration(minutes: 25);
  static const int sampleRate = 44100;
}

/// Group-chat configuration.
class GroupConfig {
  static const int minMembers = 1;
  static const int maxMembers = 100;
}

/// Onion-routing configuration.
class OnionConfig {
  /// Number of intermediate relays between sender and recipient.
  /// 0 = direct (no onion). 2 = 2 random relays (3-hop total).
  static const int relayCount = 2;

  /// Poll interval for relay hops addressed to me.
  static const Duration relayPollInterval = Duration(seconds: 10);
}

/// Passkey rules — exactly 8 chars, lowercase alphanumeric.
class PasskeyConfig {
  static const int length = 8;
  static const String pattern = r'^[a-z0-9]{8}$';
  static const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
}

/// App PIN rules — exactly 4 digits.
class PinConfig {
  static const int length = 4;
  static const String pattern = r'^[0-9]{4}$';
}

/// Available app themes.
enum AppThemeMode { system, light, dark }

