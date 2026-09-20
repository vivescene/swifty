# Swifty implementation plan

## Purpose and current boundary

This is an execution plan for the macOS-first native client described in the
build specification. It is deliberately a feasibility plan rather than a
claim of Discord interoperability. The repository currently contains a Swift
6/macOS 15 scaffold, an XcodeGen manifest, a SwiftUI/AppKit shell, four
dependency-free package modules, a tested Keychain credential adapter, and a
remote-auth transport that reaches the verified `pending_remote_init`
checkpoint and renders a real QR. The visible application still uses
fabricated in-memory client state, and the live authentication path closes on
`pending_ticket` or `pending_login`. No token exchange, real login, account
import, Gateway session, or live smoke test has worked. No phase below should
be described as complete until its exit evidence exists.

The critical path is authentication, a read-only synchronization slice, and
the DAVE-enabled media proof. These gates determine whether the project can
continue as a direct client and which implementation choices are safe to
commit to. Work on visual polish may proceed against fixtures, but must not be
used as evidence that the protocol or media path works.

The authentication gate is tracked in [Remote Authentication Feasibility](RemoteAuthFeasibility.md),
which separates unofficial protocol references and endpoint reachability from
live login or interoperability evidence.

## Working rules

Use Swift 6 strict concurrency, Swift Package Manager, and the committed
`project.yml` as the project source of truth. Keep wire models, normalized
domain models, database records, and rendered view models separate. Long-lived
transport and persistence work belongs in actors; UI state is main-actor
isolated. Introduce a dependency only after recording its pinned version or
revision, license, transitive dependencies, and reproducible build steps.

Every protocol assumption gets a source label: official documentation,
unofficial reference, or observed behavior. An observation records the test
date, app/build versions, operating-system version, dependency revisions, and
fixture or account conditions. A passing local probe is not general
interoperability evidence.

All real-account probes are manually supervised. Use fabricated fixtures for
agent work and automated tests. Never provide a production token to an agent,
never send credentials or messages through project infrastructure, and never
bypass MFA, CAPTCHA, consent, or other account protections.

## Phase 0 — Scaffold and engineering baseline

### Entry

The repository has a cleanly understood macOS target and a reproducible
headless package build. Existing client-shell behavior is treated as
presentation-only; the remote-auth QR checkpoint is the only experimental live
protocol surface, and no live Discord account is required for automated tests.

### Work

Preserve the current XcodeGen and SwiftPM split while adding only the module
boundaries needed by the next vertical slice. Establish package-level
protocols for credentials, clock, Gateway transport, REST transport,
persistence, and media discovery before adding concrete implementations.
Add CI jobs for `swift build`, `swift test`, Xcode project generation, and a
macOS application build/test destination. Pin XcodeGen and all later
dependencies. Add redacted OSLog categories and a test fixture policy before
network code exists.

The first project record should state that the app has no account service, no
relay, no required cloud database, no telemetry requirement, and is licensed
under GPL-3.0. These are product and release constraints, not implementation
details to defer silently.

### Exit gate

The same revision builds and tests from a clean checkout through SwiftPM and
the generated Xcode project. CI proves strict-concurrency settings are active,
test fixtures contain no secrets, and a reviewer can identify where future
credentials, cache records, and transport callbacks will live. A macOS smoke
run shows the disconnected fabricated shell and the explicitly labelled
remote-auth QR checkpoint. No live login, token exchange, account import,
Gateway session, or Discord interoperability is claimed.

## Phase 1 — Authentication feasibility

### Entry

The scaffold gate passes and a written threat model covers QR payloads,
session material, replay, cancellation, logout, invalidation, logging, and
authentication web content. A sacrificial account and a manually supervised
test machine are available if an external probe is approved.

### Work

Implement an isolated Auth feature and a small `CredentialStore` abstraction.
The repository now has `KeychainCredentialStore`, covered by tests through a
fake Keychain client, and `RemoteAuthTransport`, covered by protocol and crypto
fixtures. The experimental UI performs the hello/init/nonce-proof sequence,
verifies the fingerprint on `pending_remote_init`, and renders a real QR. It
must remain deliberately incomplete: close on `pending_ticket` or
`pending_login`, with no token exchange, account import, or Gateway login.
Continue investigating the user-approved desktop QR/remote-auth flow using the
unofficial reference as research material, while recording observed behavior
and verifying cryptographic parameters against the protocol. Do not put secrets
in UserDefaults, URLs, snapshots, diagnostics, or view state.

The proof must exercise approval, rejection, expiry, cancellation, session
restoration, logout, and invalidation. Test MFA, CAPTCHA, and any official-page
flow as an explicit compatibility question. The client may display or hand
off a challenge, but must not automate or bypass it. Isolate authentication
content from arbitrary message links and expose only narrowly validated native
actions.

### Manual evidence

Record a redacted test report containing OS and app/build versions, protocol
references, timestamps, state transitions, and whether each flow was observed
or remains unknown. Do not store QR secrets, tokens, screenshots containing
account material, or message content in the repository.

### Exit gate

The current checkpoint exit evidence is limited to 68 passing automated tests,
including Keychain behavior and remote-auth transport/crypto contracts, plus
the UI path to verified `pending_remote_init` and QR rendering. A repeatable,
user-approved login and logout proof does not exist: no live smoke test,
approval scan, token exchange, account import, or Gateway session has worked.
The next gate requires a manually supervised disposable-account test, policy
review, and explicit evidence before any login claim is added.

## Phase 2 — Read-only Gateway, REST, and cache vertical slice

### Entry

Authentication feasibility has passed for the narrowly supported flow, or the
team has explicitly chosen to continue only with fabricated protocol fixtures.
Credential storage and redacted diagnostics are in place.

### Work

Build small adapters around `URLSession` and `URLSessionWebSocketTask`. The
Gateway actor owns connection state, identify/resume, heartbeat acknowledgements,
sequence numbers, invalid sessions, reconnect requests, network changes, and
deterministic bounded backoff. Cancel old receive loops before starting a new
session and allow only one active connection per account session.

Decode tolerant wire models with explicit null-versus-absent handling and
unknown enum preservation. If compression is negotiated, use a tested
streaming decompressor with bounded output and fixtures split across receives;
do not assume one WebSocket receive equals one application event. Begin with a
simpler verified encoding where possible.

The REST actor consumes server-provided route and global rate-limit data,
honors cancellation, and avoids retrying authorization failures. It never
attaches a Discord Authorization header to a third-party media or upload host.
Normalize account, guild, channel, user, member, message, attachment, reaction,
read-state, permission, and voice-session data before publishing narrow store
updates.

Add GRDB/SQLite only after schema and retention decisions are reviewed. Use one
database and media namespace per account. Store bounded recent history,
metadata, drafts/read state placeholders, and synchronization cursors; keep
credentials in Keychain. Make migrations atomic and distinguish stale cache
content from currently authorized content.

### Automated evidence

Use URLProtocol and WebSocket fakes with injected clocks. Cover malformed and
unknown payloads, split compressed data, multiple events per receive, heartbeat
timeouts, resume and invalid-session paths, rate-limit headers and 429s,
cancellation, duplicate events, edits, deletions, permission loss, account
switching, and channel removal. Include migration and cache-isolation tests.

### Manual evidence

With a supervised sacrificial account, record read-only login, server/channel
listing, history pagination, reconnect behavior, and logout cleanup. Record
the exact app/build, OS, dependency revisions, and endpoint assumptions. Do
not treat cached content as proof of continued access.

### Exit gate

A read-only account session can restore, receive normalized Gateway events, fetch
the active channel through REST, persist bounded data, and recover from a
reconnect without leaking credentials across accounts. Tests demonstrate that
unknown protocol additions do not crash the session and that permission or
channel removal clears stale accessible content. Sending remains disabled.

## Phase 3 — Native messaging interface

### Entry

The read-only vertical slice supplies normalized fixture data and, where
approved, live read-only data. The cache contract and account isolation tests
pass.

### Work

Replace fabricated timeline assumptions incrementally with native message
presentation. Use SwiftUI for application structure and settings, an
`NSCollectionView` diffable data source for reusable message items and stable
pagination, and an AppKit `NSTextView`/TextKit composer host for editing,
selection, undo, paste, and input methods.

Define the rendering path as wire message → normalized model → Discord-specific
Markdown/syntax adapter → cached presentation model → reusable item. Use
swift-markdown only as a parser; explicitly implement or document mentions,
custom emoji, spoilers, timestamps, replies, embeds, code blocks, links, and
unsupported content. Keep links inert until activation and never execute
message HTML or scripts.

Add Nuke or an equivalent pinned image loader only with cancellation,
downsampling, cache bounds, and decoding budgets. Treat attachments,
thumbnails, animated formats, and Lottie data as untrusted. Add format support
deliberately rather than implying parity from PNG support alone.

### Evidence

Run a fabricated large-history scroll test and record pagination position,
off-screen work, reduced-motion behavior, keyboard-only navigation, VoiceOver
labels, and Russian and English input methods. Test edits, deletions, replies,
spoilers, embeds, custom emoji, timestamps, unsupported message types, and
malformed media fixtures.

### Exit gate

Reading older history does not jump to the newest item, pagination is stable,
and the timeline remains responsive with a large fabricated history. The
composer and navigation are usable by keyboard and VoiceOver. Presentation
does not execute remote content, exceed documented media budgets, or expose
another account's cache.

## Phase 4 — Send and reconcile

### Entry

Read-only synchronization and native composer acceptance gates pass. A
mutation threat review covers retries, duplicate sends, attachments, logout,
and permission changes.

### Work

Implement message creation through the REST adapter with explicit optimistic
state. Assign a local pending identifier, show a visible pending/failed state,
and reconcile server acknowledgement with Gateway events by stable identifiers
and content semantics. Safe reads may retry according to policy; mutations must
not be blindly retried when acknowledgement is ambiguous. Provide an explicit
retry action and preserve drafts according to the documented retention choice.

Keep attachment uploads on a separate credential boundary and verify redirect
and destination hosts before sending any request. Do not add an external
hosting provider as a hidden workaround for Discord limits.

### Evidence and exit gate

Fake transport tests cover success, cancellation, timeout after server receipt,
429s, authorization failure, duplicate Gateway delivery, edit/delete races,
logout while pending, and loss of channel permission. Manual testing against a
sacrificial account proves one send, a reconnect during send, failed-send
recovery, and account switching without cross-account state. The gate passes
only when every ambiguous state is visible and actionable; no “sent” claim is
made from a local optimistic append alone.

## Phase 5 — Media and DAVE proof

### Entry

Messaging is reliable enough to support a separate media test harness. The
team has chosen pinned libwebrtc and libdave revisions, reviewed licenses and
native build requirements, and has an official Discord client available for
manual comparison.

### Work

Build a small C++/Objective-C++ bridge owned by the project. Integrate the
selected libwebrtc media pipeline with Discord Gateway and voice signaling, and
use official `discord/libdave` for DAVE frame encryption and MLS session
operations. Keep real-time callbacks free of database access, UI calls, and
avoidable allocations. Inspect the actual framework build for frame
encryption/decryption hooks rather than assuming a Swift wrapper exposes them.

Choose one primary transport strategy after the proof. Abaddon's source may
inform UDP/Opus and DAVE work, but it is not a drop-in Swift video SDK and does
not justify carrying two speculative stacks.

Implement participant and stream mapping, speaking state, device changes,
mute/deafen, reconnects, codec negotiation, and encryption transitions. Never
add an unencrypted fallback to make a failing interoperability test pass.
Keep DAVE frame encryption conceptually separate from negotiated media
transport protection.

### Manual evidence

Record results for two-way audio with an official client, multiple participants
joining and leaving, mute/deafen, microphone and headphone changes, permission
denial, camera start/stop, receiving another participant's stream, and network
interruption/reconnect. Each report includes machine, OS, app/build,
libwebrtc/libdave revisions, codecs, and observed failures.

### Exit gate

The project demonstrates a real DAVE-enabled call with an official client for
the supported scope, including encryption transitions and reconnect behavior.
If the proof fails, media remains explicitly unsupported and the project does
not advertise voice, video, or a stock-WebRTC demo as equivalent capability.

## Phase 6 — Screen sharing

### Entry

The media/DAVE gate passes for the selected transport and codec path. Capture,
microphone, camera, and system-audio permissions have an explicit lifecycle.

### Work

Use ScreenCaptureKit and the system content-sharing picker. Feed captured frames
into the proven live-media pipeline rather than treating capture as a stream
implementation. Keep microphone and shared application/system audio separate
until the intended mixing point, and prevent remote-call audio feedback. Prefer
the media engine's hardware codec integration; use VideoToolbox directly only
where the selected architecture requires it, without encoding twice.

### Evidence and exit gate

Manually test window and display selection, intended shared audio, permission
denial and revocation, stop-on-logout/cancellation, camera plus screen sharing,
remote reception, network interruption, and resource cleanup. Record actual
machine and permission results. The gate passes only when a real participant
can receive the shared stream through the proven Discord path; capture-only
output is not sufficient.

## Phase 7 — Extensions, themes, and local RPC

### Entry

Core messaging and any supported media scope have passed their release gates.
The project has a stable permission model and a documented account/data
boundary.

### Work

Start with reviewed Swift feature modules compiled into releases. Expose narrow
interfaces for message actions, composer commands, settings sections, and
presentation transformations. Pass typed data and explicit actions only; do
not expose tokens, database handles, unrestricted HTTP, or arbitrary native
code. Existing Vencord plugins are not a compatibility target because the
native client has no Discord JavaScript/webpack patch environment.

Implement themes as validated JSON/Codable design tokens for colors, spacing,
density, and typography roles. Do not download native libraries. A future
scripting system requires capability checks, process isolation, resource
limits, and a threat model before choosing JavaScriptCore or another runtime.

If Rich Presence is added, build a small opt-in local Swift IPC service based on
arRPC and Discord RPC documentation. Restrict commands, validate callers, and
avoid an unauthenticated LAN listener. App Intents or a later MCP interface
starts with narrow navigation/read actions; sending, uploading, or exposing
message content requires explicit user-controlled permission.

### Exit gate

Feature modules are reviewable, versioned, and covered by permission tests.
Theme parsing rejects unsafe or malformed input. RPC and automation tests show
that no token or unrestricted data path is exposed. No feature is described as
a Vencord plugin unless it is independently reimplemented and tested.

## Phase 8 — Release hardening and distribution

### Entry

The selected feature scope has passed its functional gates, and unresolved
protocol or media gaps are documented as unsupported rather than hidden.

### Work

Complete failure-path testing for account switching, logout, permission loss,
network changes, cache migration, malformed remote input, media cancellation,
and resource cleanup. Add diagnostics based on OSLog with secret and message
redaction, plus a user-visible preview before exporting a diagnostic bundle.
Document cache retention and clearing, including that Keychain protection does
not encrypt the SQLite cache by itself.

Set up Developer ID signing, Hardened Runtime, notarization, Sparkle 2 signed
updates, stable/beta feeds, and release archives. Keep signing and update keys
in protected release infrastructure, never in pull-request jobs or the
repository. Protect CI from untrusted pull requests and pin toolchains and
dependency revisions. Confirm the committed GPL-3.0 license remains
compatible with the application and all dependencies before each release.

Run Swift Testing/XCTest unit and adapter suites, XCUITest on a real macOS
destination, accessibility inspection, Instruments profiling, release archive
validation, and clean-install/update/uninstall checks. Publish the tested OS,
hardware, dependency revisions, supported Discord flows, known limitations,
and manual evidence summary with each release.

### Exit gate

A clean machine can install, launch, sign in through the supported flow, use
the documented feature scope, update through a signed feed, and remove local
credentials and data according to the retention choice. Notarization,
signature verification, crash-log redaction, accessibility checks, and release
rollback procedures are demonstrated. The release notes state that the client
cannot guarantee ban-free status, reproduce server permissions, grant Nitro
entitlements, or remove Discord-enforced attachment limits.

## Explicit non-goals

The first release does not replace Discord's service, operate an account or
message relay, require a project cloud database, or collect mandatory
telemetry. It does not promise iPad, Windows, or Linux support; existing
Vencord plugin compatibility; every Discord login method; Nitro entitlement
substitution; arbitrary remote extensions; an external upload service; or
MCP-driven message sending.

Voice, video, DAVE, and screen sharing are not inferred from a web view,
WebRTC sample, audio attachment playback, or capture API demo. A feature is
supported only after the corresponding manual interoperability evidence and
security/privacy gate pass.

## Evidence register

Keep a small versioned evidence record beside implementation work. At minimum
it should identify the phase, commit, OS and hardware, Xcode and dependency
versions, source classification, fixture or supervised-account conditions,
observed result, known limitations, and reviewer. Redact account identifiers,
tokens, QR material, message content, and private media. A phase status is
`planned`, `in progress`, `blocked`, or `passed`; only `passed` permits the
next phase to claim the gated capability.
