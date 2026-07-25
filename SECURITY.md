# Send — Security Policy

## Threat model

Send assumes the following:

- **The Supabase server is untrusted.** It can read the ciphertext, iv,
  metadata (timestamps, identity ids, attachment paths), and observe the
  timing and volume of traffic. It cannot read plaintext messages,
  attachment contents, or derive shared symmetric keys.
- **Network observers** (ISPs, Wi-Fi operators) can see HTTPS traffic
  patterns but not contents (TLS 1.2+).
- **The recipient's device** is trusted. If the recipient is compromised,
  plaintext messages they have decrypted will be exposed.
- **The sender's device** is trusted. If the sender's keystore is
  compromised, their private key is exposed and all their conversations can
  be decrypted.

## What Send protects against

- **Server-side plaintext exposure** — even with full database access,
  messages cannot be decrypted without the per-peer shared keys.
- **Replay attacks** — each AES-GCM nonce is fresh per message; replays
  fail integrity verification.
- **Code-reuse attacks** — rotating codes are one-shot. Once resolved,
  they cannot be reused by another party.
- **Stale data leaks** — identities auto-delete after 30 days of
  inactivity, limiting the blast radius of forgotten accounts.

## What Send does NOT protect against

- **Compromised endpoints** — if your device is rooted or has malware with
  accessibility permissions, plaintext can be extracted at the screen or
  keystore level.
- **Metadata analysis** — the server knows who is talking to whom, when,
  and how much. Send does not currently implement mix-networking or
  timing obfuscation.
- **Quantum attacks** — X25519 is not post-quantum secure. A future
  version may integrate ML-KEM (Kyber) for hybrid post-quantum key
  agreement.
- **Social engineering** — if you share your rotating code with the wrong
  person, they can send you a friend request.

## Cryptographic choices

| Component | Choice | Rationale |
|---|---|---|
| Key exchange | X25519 | RFC 7748, audited, widely deployed |
| Symmetric cipher | AES-256-GCM | FIPS-compliant, hardware-accelerated on Android |
| Key derivation | HKDF-SHA256 | RFC 5869, binds key to peer pair via info string |
| RNG | OS CSPRNG | `cryptography` package delegates to platform RNG |
| Auth token | 32 random bytes (hex) | 256-bit entropy, sufficient for header-based auth |

## Reporting a vulnerability

If you discover a security issue, please report it responsibly:

1. **Do NOT open a public GitHub issue.**
2. Email [create an issue marked "security" on GitHub](https://github.com/NaitikMaladkar/Send/security/advisories/new)
   or DM the maintainer via the GitHub Security Advisory mechanism.
3. Include a clear description of the issue, reproduction steps, and
   affected versions.
4. You will receive an acknowledgment within 72 hours and a fix timeline
   within 14 days.

## Disclosure policy

- We follow coordinated disclosure. Once a fix is released, we will
  publish a GitHub Security Advisory crediting the reporter (unless they
  prefer to remain anonymous).
- We request a 90-day embargo before public disclosure of unpatched
  vulnerabilities.

## Security audit

Send has not undergone a formal third-party security audit. The codebase
is small (< 1500 LOC of Dart) and reviewable by a single auditor in a
few hours. If you perform an audit, please share your findings.

## Signing

Release APKs are signed with a 2048-bit RSA key (validity: 100 years).
The SHA-256 fingerprint of the signing certificate is published in each
GitHub release. Verify before installing:

```bash
keytool -printcert -jarfile send-v1.0.0-release.apk | grep SHA256
```

Compare against the fingerprint listed in the release notes.
