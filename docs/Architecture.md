# Swifty architecture

## scope

This is a macOS 15+ Swift 6 application scaffold. `project.yml` is the
XcodeGen source of truth: it builds three framework targets, the application,
and one aggregate unit-test target. `Package.swift` exposes the same three
contract modules as independent SwiftPM products and test targets.

There is no live Discord network client, Keychain implementation, database, or
cache engine here. The current modules define boundaries, validated values,
state machines, and testable policies for those future adapters.

## source and dependency layout

```text
Sources/
├── DiscordCore/              Gateway, rate-limit, snowflake, transport safety
├── AuthFeature/              Remote-auth models, state machine, credential port
├── CacheCore/                Cache identity, retention, access, and outbox ports
└── SwiftyApp/                SwiftUI shell and feature composition

Tests/
├── DiscordCoreTests/
├── AuthFeatureTests/
└── CacheCoreTests/
```

`DiscordCore`, `AuthFeature`, and `CacheCore` have no SwiftPM target
dependencies. The Xcode application depends on all three framework targets;
the app is the composition root. Keep transport, persistence, and Keychain
implementations outside these contract modules and inject them through their
protocols or value types. Do not make a shared contract import SwiftUI,
AppKit, a database engine, or a live service client.

Swift 6 language mode and complete strict-concurrency checking are enabled.
Cross-actor values are `Sendable`; UI orchestration belongs to the main actor,
while eventual network, credential, and persistence adapters should be actors.

## DiscordCore contracts

`GatewayOpcode` preserves unknown wire opcodes instead of failing decoding.
`GatewayConnectionState`, `GatewayDisconnectReason`, and `ExponentialBackoff`
describe connection lifecycle and deterministic retry policy; they do not open
websockets or schedule work.

`RateLimitObservation` loss-tolerantly parses server headers and 429 JSON,
while `RateLimitSnapshot` merges partial route/global observations. It records
what the server supplied and leaves clocks, expiry, and request scheduling to a
future adapter.

`CredentialAttachmentPolicy` only permits HTTPS requests to the exact compiled
Discord API hosts and `/api` paths. Redirect destinations are evaluated again,
so credentials are not trusted transitively. `Snowflake` remains an exact
decimal string to avoid integer precision loss.

## AuthFeature state machine

`AuthStateMachine` is deterministic and transport-free. Its principal path is:

```text
idle → awaitingQRCode → pendingApproval → approved
                                      ↘ cancelled / expired / rejected
approved → loggedOut
approved → invalidated
restoring → restored / loggedOut / failed
```

`AuthEvent` values are the only inputs. Session expiry, account mismatch,
invalid transitions, and restoration failures are explicit errors or states.
`AuthCoordinator` is an actor around that machine and an injected
`CredentialStore`; credential bytes remain opaque to the state model. The
`InMemoryCredentialStore` exists for deterministic tests only, not production
security.

Ordinary OAuth is not a supported general replacement-client login. The first
authentication feasibility gate is an explicitly user-approved desktop QR /
remote-auth flow based on unofficial Userdoccers references. Treat it as
compatibility work, not a Discord-supported contract: record observed behavior,
client/build version, exact test date, and a threat model for QR payloads,
session material, and replay. Never ask for passwords, send credentials to
project infrastructure, bypass MFA/CAPTCHA, automate a challenge, or claim
interoperability that was not observed. See
[Remote Authentication Feasibility](RemoteAuthFeasibility.md) for the current
protocol evidence, policy boundary, and supervised test matrix.

## CacheCore contracts

`CacheAccountNamespace`, `CacheObjectID`, and `CacheChannelID` validate logical
identifiers and keep account identity separate from credentials. `CachePresence`
and `CacheAuthorization` are deliberately separate, so cached data is never
treated as proof of current access.

`CacheAccessCommand` describes authorization revocation and scoped removal.
`DraftRecord` and `PendingSendRecord` define local outbox data; pending sends
progress conceptually from `queued` through `sending` and acknowledgement, or
to an explicit failed/cancelled state. `CacheRetentionPolicy` contains bounds
only. None of these types writes, deletes, encrypts, uploads, or sends data.

## validation

Tests exercise pure transitions, parsing, redaction, identity validation,
credential attachment, and retention/outbox invariants. Future adapters must
use fakes and injected clocks; QR probes are opt-in and should use a
sacrificial account with dated, reproducible observations. The manifests have
no third-party dependencies. If one becomes necessary, document why a system
framework is insufficient, pin an exact release, commit `Package.resolved`,
and review its license and transitive dependencies.
