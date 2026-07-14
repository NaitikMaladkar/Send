/// Send — public Supabase config.
///
/// These values are intentionally committed to the repo. The anon key is
/// designed to be embedded in client apps — Row Level Security on every
/// table ensures it cannot read or write data without a valid per-identity
/// auth token issued by `register_identity()`.
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
class DisappearingConfig {
  static const int minSeconds = 3600;       // 1 hour
  static const int defaultSeconds = 604800; // 7 days
  static const int maxSeconds = 2592000;    // 30 days

  /// Preset choices offered in the UI.
  static const List<({String label, int seconds})> presets = [
    (label: '1 hour',  seconds: 3600),
    (label: '24 hours', seconds: 86400),
    (label: '7 days',   seconds: 604800),
    (label: '14 days',  seconds: 1209600),
    (label: '30 days',  seconds: 2592000),
  ];
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

/// Available app themes.
enum AppThemeMode { system, light, dark }
