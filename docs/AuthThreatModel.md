# Authentication threat model

## status and scope

This document covers the authentication feasibility foundation for the native
macOS client. It covers the proposed user-approved desktop QR or remote-auth
flow, restoration from a local credential store, logout, invalidation, and the
state transitions around cancellation, expiry, approval, and rejection.

The remote-auth protocol is unofficial. Userdoccers is a protocol reference,
not a Discord compatibility or security guarantee. The implementation must
record the observed client/build version, protocol revision or reference, and
test date for every manually supervised probe. This foundation intentionally
contains no Discord endpoint, QR payload, token, cryptographic claim, or web
bridge.

## assets and trust boundaries

The sensitive assets are QR session material, any public-key operation inputs
or outputs used by a future protocol adapter, credential material, account
identity, local cached content, and authentication-related diagnostics.

The user, Discord, the local application process, the macOS Keychain, the
future protocol adapter, arbitrary message links, and project infrastructure
are separate trust boundaries. A generic web page or message link is never an
authentication surface. A future Keychain adapter must keep credential bytes
inside the adapter boundary and expose only success, failure, or an opaque
reference to feature state.

The state machine uses redacted descriptions by design. Account labels and
remote-auth session identifiers are not emitted in state descriptions. QR
payload bytes and credentials are not represented by the remote-auth state
types.

## security assumptions

The user explicitly initiates a login and can see which account is requesting
approval. The user supervises the QR scan and any browser or system challenge.
macOS Keychain Services protects stored credential material according to the
device's security configuration. Discord remains authoritative for session
validity, MFA, CAPTCHA, permissions, and account status.

These assumptions do not imply that a local client is trusted by Discord, that
an unofficial protocol will remain stable, or that a successful experiment is
general interoperability evidence.

## abuse cases and controls

### credential exfiltration

The client must never send passwords, QR session secrets, tokens, or Keychain
material to project infrastructure. There is no project-operated account
system, relay, analytics endpoint, or required cloud database. Credentials are
stored only through the account-scoped Keychain adapter and are excluded from
URLs, logs, crash reports, screenshots, snapshots, UserDefaults, and source
control.

Coding agents must use fabricated fixtures. They must never receive a
production account token or a copied production QR payload. Local integration
testing uses a sacrificial account under direct human supervision.

### QR interception and confused approval

An attacker or malicious page could present a QR intended for another account
or make a user approve an unexpected device. The UI must show the account
identity available from the protocol before approval, require an explicit user
action, and never relay a login QR through project services. A hint mismatch
must leave the state pending and fail closed; it must not silently approve a
different account.

### replay, expiry, and stale state

Remote-auth session references are short-lived and have an explicit expiry.
The deterministic state machine transitions waiting or pending approval to an
expired state at the deadline. Approval after expiry cannot succeed. Transport
adapters must cancel old receive loops and reject stale events associated with
an earlier session.

### MFA and CAPTCHA bypass

MFA, CAPTCHA, device verification, and similar challenges are not bypassed,
automated, proxied, or weakened. A challenge requirement is surfaced as a
rejection or an explicitly unsupported flow. The project does not claim to
support every login method until each one has been manually verified.

### malicious authentication web content

If a future official-page or challenge flow uses web content, it must run in an
isolated authentication context. Message links and arbitrary embeds must never
share that context or receive a privileged JavaScript-to-native bridge.
Redirects and destination hosts must be checked before any credential-bearing
operation. Web content does not receive unrestricted token, database, or HTTP
client access.

### local compromise and residual data

Logout removes the account credential through the injected credential-store
protocol and stops any active capture or session work. Invalidation removes
the credential and produces a distinct invalidated state. Local message caches
are separate from Keychain credentials; retention and clearing behavior must
be explicit and user-visible. This project does not market cache deletion or
Keychain storage as protection against a compromised host.

### diagnostic leakage

Routine diagnostics redact authentication state and credential values. An
exported diagnostic bundle requires a user preview and must omit secrets,
message content, QR material, and arbitrary response bodies by default. Error
types should use stable categories instead of embedding server text that may
contain sensitive data.

## manual verification gates

Before calling the flow feasible, manually verify user-approved login,
rejection, cancellation, expiry, restoration, logout, and invalidation on a
real supported macOS build. Verify MFA and CAPTCHA handling by stopping at the
challenge; do not attempt to defeat it. Verify that the account shown before
approval matches the account restored afterward.

The test record must include the macOS version, app build, dependency and
protocol revisions, account type used for the probe, observed timestamps, and
whether the result was reproducible. One successful probe is not evidence of
general compatibility. Failures must remain visible rather than being
converted into an unencrypted fallback or an unverified success state.

## release gates and non-goals

No release may claim supported login until the manual gates pass and the
threat-model assumptions are reviewed. No production credential may enter CI,
pull-request jobs, fixtures, or agent context. Signing keys and update keys
belong in protected release infrastructure.

This document does not authorize credential collection, protocol reverse
engineering beyond the user-approved feasibility work, bypassing Discord
security controls, or shipping a web client as native feature parity. It does
not assert that a QR flow is currently supported, safe for all accounts, or
stable against Discord changes.
