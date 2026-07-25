# Send

> Anonymous, end-to-end encrypted chat for Android. No phone number. No email. No tracking.

**Send** is a minimalist Flutter chat app that uses **X25519 ECDH** for key agreement,
**AES-256-GCM** for message encryption, and **Supabase** as a thin relay. The server
never sees plaintext, message keys, or your private identity — only opaque ciphertext
blobs and rotating shareable codes.

![version](https://img.shields.io/badge/version-1.0.0-indigo)
![platform](https://img.shields.io/badge/platform-Android%208.0%2B-green)
![license](https://img.shields.io/badge/license-MIT-blue)

---

## Features

- **Anonymous identity** — generated locally on first launch. No phone number, no email.
- **End-to-end encryption** — X25519 + HKDF-SHA256 + AES-256-GCM. The Supabase server
  only ever stores ciphertext + iv; private keys never leave the device.
- **Rotating shareable codes** ("MyLink") — 24-hour one-shot codes for adding friends.
  A fresh one is generated on demand; old ones auto-expire.
- **Multi-account** — create and switch between multiple anonymous identities on the
  same device. Useful for separating work, friends, and burner conversations.
- **Auto-wipe** — after 30 days of inactivity, the server cron job deletes your
  identity, all your messages, and all your friend requests. Attachments in storage
  are also dropped (their path becomes unreachable).
- **Attachments** — images (up to 10 MB) and PDFs (up to 25 MB), encrypted with the
  same shared key and uploaded to a private Supabase Storage bucket.
- **Foreground service** — keeps the websocket + polling loop alive in background so
  incoming messages surface as local notifications without Firebase Cloud Messaging.
- **No Firebase, no Google Play Services required** — works on de-Googled Android.

## Cryptographic stack

| Layer | Algorithm | Notes |
|---|---|---|
| Identity keys | X25519 | 32-byte private seed stored in Android Keystore via `flutter_secure_storage` |
| Key agreement | ECDH | `myPrivate × theirPublic` per peer pair |
| Key derivation | HKDF-SHA256 | 32-byte output, info = `send:v1:{myId}.{peerId}` |
| Symmetric cipher | AES-256-GCM | 12-byte random nonce per message, 16-byte auth tag |
| Attachment format | `iv ‖ ciphertext` | Stored as a single blob in Supabase Storage |
| Message format | `ciphertext ‖ tag` (base64) | Row also stores `iv` and `kind` |
| Per-identity auth | random 32-byte hex token | Sent as `X-Identity-Id` + `X-Identity-Token` headers on every RPC |

## Architecture

```
┌──────────────┐                ┌──────────────────┐                ┌──────────────┐
│  Send app    │  HTTPS (RPC)   │  Supabase        │  HTTPS (RPC)   │  Send app    │
│  (Flutter)   │ ◄────────────► │  Postgres + RLS  │ ◄────────────► │  (Flutter)   │
│              │                │  + Storage       │                │              │
│  • Keystore  │                │  • identities    │                │  • Keystore  │
│  • Crypto    │                │  • codes         │                │  • Crypto    │
│  • Chat Svc  │  WebSocket     │  • friend_reqs   │                │  • Chat Svc  │
│  • Notify    │ ◄────────────► │  • messages      │                │  • Notify    │
└──────────────┘                └──────────────────┘                └──────────────┘
```

All RPCs are `SECURITY DEFINER` Postgres functions that verify the request headers
against `identities.auth_token` before performing any operation. RLS on every table
is set to `using(false)` so direct table access is impossible even with the anon key.

## Installation

### From a release APK

1. Download the latest `send-vX.Y.Z-release.apk` from the
   [Releases page](https://github.com/NaitikMaladkar/Send/releases).
2. On Android 8+, allow "Install unknown apps" for your browser or file manager.
3. Open the APK and tap **Install**.
4. Launch **Send** and tap **Create my anonymous identity**.

### Build from source

```bash
git clone https://github.com/NaitikMaladkar/Send.git
cd Send
flutter pub get
# Generate your own keystore (do NOT reuse the example one)
keytool -genkey -v -keystore android/app/send-keystore.jks \
  -storetype JKS -keyalg RSA -keysize 2048 -validity 36500 -alias send
# Fill in android/key.properties with the passwords you chose
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

## Usage

1. **Create identity** — on first launch, tap the button. A keypair is generated
   locally; only the public key is uploaded. You get a 7-digit display code
   (informational only — it's not used for login).
2. **Add a friend** — go to the **Friends** tab → **Add friend**. Tap
   **Generate code** to get a 24-hour one-shot code. Share it with your friend
   via any channel. They paste it on their end and send you a friend request.
3. **Accept incoming** — when someone sends you a friend request, you'll see it
   in the Friends tab. Accept to start chatting.
4. **Chat** — open a friend → type a message, or use the image/pdf buttons to
   send attachments. All messages are encrypted with the per-peer shared key.
5. **Multi-account** — Profile → **Create another identity** to spin up a second
   anonymous account. Switch between them from the same screen.
6. **Delete** — Profile → **Delete active identity** to wipe the local keypair
   and friend list. The server-side row is dropped within 24 hours by the
   cleanup cron.

## Privacy

See [PRIVACY.md](PRIVACY.md) for the full privacy policy. Highlights:

- **No personal data** is collected. The server stores only: a public key, a
  random auth token, ciphertext blobs, and rotating shareable codes.
- **No analytics, no telemetry, no advertising SDKs.**
- **30-day inactivity auto-delete** — if you stop using the app for 30 days,
  your identity is permanently erased server-side. There is no recovery.

## Security

See [SECURITY.md](SECURITY.md) for the threat model and disclosure policy.

## Tech stack

- **Flutter 3.27** + Dart 3.6
- **supabase_flutter 2.15** — Postgres RPCs, Storage, Realtime
- **cryptography 2.9** — X25519, AES-GCM, HKDF
- **flutter_secure_storage 9** — Android Keystore-backed key storage
- **flutter_foreground_task 8** — background websocket keep-alive
- **flutter_local_notifications 17** — local push without FCM
- **provider 6** — state management

## License

[MIT](LICENSE) © 2026 Naitik Maladkar

## Acknowledgements

Built on top of excellent open-source work from the Flutter, Supabase, and
Dart cryptography communities.
