# Remote Authentication Feasibility

Research date: 2026-09-20

Status: feasibility note for Swifty. This is not a working login implementation
and does not claim Discord interoperability.

## Scope and evidence boundary

Discord's official documentation describes OAuth2 and the Discord Social SDK for
applications that request approved scopes. It does not document a general
replacement-client login that obtains a normal desktop user session and runs the
full Discord client protocol. See the [official OAuth2 documentation](https://docs.discord.com/developers/topics/oauth2)
and [Social SDK authentication documentation](https://discord.com/developers/docs/social-sdk/authentication.html).

The QR/remote-auth material referenced below comes from
[Discord Userdoccers](https://docs.discord.food/remote-authentication/overview),
also known as discord.food. It is an unofficial, reverse-engineered reference,
not a Discord API contract. Every Swifty implementation and test report must
label behavior from this source as unofficial or observed.

On 2026-09-20, a credential-free WebSocket probe from the development macOS
host connected to `wss://remote-auth-gateway.discord.gg/?v=2` with
`Origin: https://discord.com`. The endpoint returned `101 Switching Protocols`
and a text `hello` frame containing `heartbeat_interval: 41250` and
`timeout_ms: 314713`. This establishes endpoint reachability and an initial
protocol response on that network only. It does not establish QR approval,
token exchange, Gateway login, or general interoperability.

## Unofficial desktop protocol

The detailed phase descriptions are in the [unofficial desktop reference](https://docs.discord.food/remote-authentication/desktop)
and [unofficial mobile reference](https://docs.discord.food/remote-authentication/mobile).

### Connection and key exchange

The documented WebSocket endpoint is static:
`wss://remote-auth-gateway.discord.gg/?v=2`. The documented accepted origins
are `https://discord.com`, `https://ptb.discord.com`, and
`https://canary.discord.com`. The server first sends `hello`, which supplies the
heartbeat interval and a short session timeout. Swifty must heartbeat, require
heartbeat acknowledgements, and terminate a zombie connection.

The desktop client generates an ephemeral 2048-bit RSA-OAEP keypair and sends
the base64-encoded DER SubjectPublicKeyInfo in `init`. The gateway returns an
encrypted nonce. The client decrypts it with RSA-OAEP using SHA-256 and sends
the result as unpadded base64url in `nonce_proof`.

After the proof succeeds, the gateway sends `pending_remote_init` with a
fingerprint. Swifty must independently calculate the base64url-encoded,
unpadded SHA-256 digest of the public key and compare it with the received
fingerprint before displaying `https://discord.com/ra/<fingerprint>` as a QR
payload. A mismatch must close the session and start a new attempt.

### Mobile approval and finalization

The already authenticated mobile Discord client scans the QR fingerprint and
creates a remote-auth session with `POST /users/@me/remote-auth`. The mobile
client receives a handshake token and must present an explicit accept or deny
decision. Acceptance uses `POST /users/@me/remote-auth/finish`; cancellation
uses `POST /users/@me/remote-auth/cancel`.

After the scan, the desktop receives an encrypted user payload. It decrypts the
payload locally for account confirmation, then receives either a pending login
ticket or a cancellation event. A pending login ticket is exchanged with the
unauthenticated `POST /users/@me/remote-auth/login` endpoint. The response
contains an encrypted authentication token, which the desktop decrypts with
the same private key.

That decrypted value is a highly sensitive user credential. It must never be
sent to Swifty infrastructure, placed in a URL, logged, included in crash
reports or snapshots, shown in diagnostics, committed to fixtures, or pasted
into an agent conversation. The project must never ask a tester to paste a
token. Only an explicitly approved persistence path may place the final
credential in Keychain; the ephemeral key, QR fingerprint, handshake token,
ticket, and decrypted user payload should be discarded when the attempt ends.

The unofficial reference documents close codes `4000` for invalid version,
`4001` for decode error, `4002` for handshake failure, and `4003` for timeout.
The same page describes some handshake failures as `4001`, so Swifty should
record raw close codes and avoid treating the prose distinction as stable.

## Cryptography and platform fit

Apple's [Security framework RSA-OAEP documentation](https://developer.apple.com/documentation/security/seckeyalgorithm/rsaencryptionoaepsha256)
and [SecKey encryption guidance](https://developer.apple.com/documentation/security/using-keys-for-encryption)
provide `SecKey` operations for RSA-OAEP SHA-256, including private-key
decryption. This makes Security.framework a reasonable first adapter. It is
not proof of Discord compatibility: Swifty must verify key attributes, SPKI
encoding, OAEP hash and MGF parameters, standard versus URL-safe base64, and
padding against deterministic fixtures before a live account test.

The crypto adapter should be isolated behind a protocol and tested with known
vectors plus malformed-input cases. Generate a fresh keypair per login attempt;
do not persist it as a device identity unless a later protocol observation
requires that decision. Do not replace the documented RSA-OAEP operation with a
different CryptoKit primitive merely because it is convenient.

## MFA, CAPTCHA, and policy risk

The unofficial mobile page marks finishing remote auth as “MFA may be
required.” Swifty must not bypass MFA, CAPTCHA, device checks, suspicious-login
checks, or consent. An unsupported challenge should stop the flow and direct
the user to the official Discord client.

The unofficial [CAPTCHA handling reference](https://docs.discord.food/topics/captcha-handling)
says user-account requests may return hCaptcha data and require a user-presented
challenge followed by challenge headers. Swifty must not include a CAPTCHA
solver or blindly retry challenge responses.

Discord's [self-bot notice](https://support.discord.com/hc/en-us/articles/115002192352-Automated-User-Accounts-Self-Bots)
says automating normal user accounts outside the bot/OAuth2 API is forbidden.
Discord's [platform-manipulation policy](https://discord.com/safety/platform-manipulation-policy-explainer-oct-2023)
says modifying the Discord client, including its appearance or layout, is not
allowed. The [Terms of Service](https://discord.com/terms) also prohibit
unauthorized software and scraping. These are material policy and distribution
risks, not a legal determination that any specific Swifty build is permitted or
forbidden. The project should seek Discord permission or partner guidance before
shipping remote-auth login as a public full-client feature.

## Supervised test matrix

Live tests must use a disposable, manually supervised account and the official
Discord mobile app. Use redacted diagnostics and never perform destructive or
bulk actions during the first test.

| Scenario | Expected evidence | Credential rule |
| --- | --- | --- |
| Gateway hello | `101`, valid `hello`, heartbeats and acknowledgements | no account credential involved |
| QR generation | fingerprint matches local public-key digest | never log or screenshot the QR |
| Approval | account identity is shown before acceptance; encrypted payload decrypts | token remains local and redacted |
| Cancellation | mobile denial reaches Swifty and the session closes cleanly | discard key and handshake material |
| Expiry and timeout | expired QR and `4003` become user-visible retry states | do not retry indefinitely |
| Invalid fingerprint | mismatch aborts and reconnects | never scan or accept a mismatched payload |
| MFA or CAPTCHA | flow stops or hands off to an official challenge | no bypass or solver |
| Restoration and logout | Keychain restoration works; logout removes the selected secret and local account data | never request a pasted token |
| Network interruption | receive loop and heartbeat recover without duplicate sessions | no credential in logs |

Record OS version, Swifty build, protocol reference revision or URL, timestamp,
raw redacted state transitions, and what remains unknown. If a real credential
is exposed or the result is uncertain, revoke sessions through Discord's
official security settings and remove the local Keychain item.

## Smallest safe implementation step

Build a fixture-backed `RemoteAuthSession` state machine and a
`RemoteAuthCrypto` protocol first. The initial live capability should stop at
`connecting → hello → init → nonce proof → pending remote init`, with heartbeat
handling and fingerprint verification. Add fake transcripts for split WebSocket
frames, malformed JSON, invalid proofs, timeout, cancellation, and unknown
opcodes.

Keep ticket exchange, decrypted-token handling, and Keychain persistence behind
an explicit development gate until policy review and a supervised end-to-end
test have both passed. A successful hello probe is useful evidence for the
transport adapter; it is not permission, authentication, or interoperability.
