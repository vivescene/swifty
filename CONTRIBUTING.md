# Contributing to Native Discord Client

Native Discord Client is an experimental, publicly developed macOS client scaffold. It is built with SwiftUI and AppKit and is intended to connect directly to Discord without a project-operated account service, message relay, subscription backend, or required cloud database.

The repository is currently an architecture and bootstrap project. It is not a working Discord client and does not claim tested Discord interoperability. The application displays fabricated in-memory state. Live authentication, Gateway and REST sessions, synchronization, persistence, message sending, voice and video, DAVE encryption, screen sharing, notifications, and release operations are not implemented or verified yet.

Read the [README](README.md), [architecture notes](docs/Architecture.md), [implementation plan](docs/ImplementationPlan.md), and [authentication threat model](docs/AuthThreatModel.md) before proposing work that crosses a module boundary.

## What contributions fit

The most useful contributions are small, testable improvements to the current contracts, documentation, fixtures, accessibility, reliability, and development tooling. Work should preserve the staged implementation plan and make the project easier to validate.

Large features, protocol implementations, media stacks, authentication changes, persistence engines, new extension systems, and dependency additions need a short proposal before implementation. A proposal should explain the user-visible goal, affected boundaries, security and privacy implications, test strategy, and how the change fits the current phase. Opening a pull request is not a guarantee that the direction will be accepted.

Bug reports and focused fixes are welcome. Please include the macOS version, Xcode and Swift versions, reproduction steps, relevant logs with sensitive data removed, and whether the issue is reproducible with fabricated fixtures or requires a supervised real-account test.

The repository shape is intentionally smaller than the long-term architecture described in the [implementation plan](docs/ImplementationPlan.md). Do not create speculative directories, placeholder subsystems, or abstractions without a second implementation or a testing purpose. A contribution is complete only when its stated evidence exists: code being written is not proof that a milestone, protocol, or interoperability claim is complete.

## Development prerequisites

Development targets macOS 15 or later with a stable Xcode release that supports Swift 6. The package uses Swift Package Manager. The generated macOS application project uses XcodeGen; generated Xcode project files are derived artifacts and must not be hand-edited.

From the repository root:

```sh
swift build
swift test
xcodegen generate
open NativeDiscordClient.xcodeproj
```

After generating the project, the application and Xcode test scheme can also be exercised from the command line:

```sh
xcodebuild \
  -project NativeDiscordClient.xcodeproj \
  -scheme NativeDiscordClient \
  -destination 'platform=macOS' \
  test
```

The current tests use fabricated values and do not require a Discord account, token, client secret, signing identity, or project service. Do not add credentials to make a local test pass.

## Architecture boundaries

Keep native presentation, protocol adapters, persistence, authentication, and media bridges separate. The current Swift package exposes three dependency-free libraries:

- `DiscordCore` contains protocol and transport-independent contracts such as Snowflakes, Gateway state, backoff, rate-limit observations, and credential-destination policy.
- `AuthFeature` contains the transport-free authentication state machine, coordinator, redacted account models, and fixture-only in-memory credential store.
- `CacheCore` contains account namespaces, authorization and presence state, retention bounds, drafts, pending sends, and removal commands.

The application target contains the SwiftUI and AppKit shell and temporary presentation state. Package modules should remain independent of SwiftUI and AppKit. Long-running work belongs in actors or bounded asynchronous queues; UI state is main-actor isolated under strict Swift 6 concurrency checking.

Keep the dependency direction explicit: UI depends on service protocols and domain models; transport, persistence, and media adapters implement those protocols; test support supplies substitutes. Protocol code should not import SwiftUI, and real-time media callbacks must not depend on database work. Future adapters should be small and explicit. Do not create a single global `DiscordService`, mix database access into real-time callbacks, or let view models own transport and credential policy. Keep wire models, database records, normalized domain models, and rendered presentation models distinct. Preserve absent-versus-null update semantics and tolerate unfamiliar protocol fields and enum values.

The current in-memory credential store is a test fixture, not production storage. A production implementation must use Security.framework Keychain Services and must be designed separately from the local message cache.

## Security, authentication, and privacy

Production Discord tokens must never be shared with contributors, coding agents, CI, issue trackers, logs, screenshots, test fixtures, or source control. Real-account interoperability testing is manually supervised. Use fabricated values and protocol fixtures for automated work.

Never send Discord credentials, QR session secrets, messages, diagnostics, or account data to project infrastructure. Do not bypass MFA, CAPTCHA, approval, expiry, or cancellation challenges. Authentication web content must be isolated from arbitrary message links, and any bridge must expose only narrowly validated actions.

Treat protocol payloads, remote media, embeds, files, links, authentication content, and future extensions as untrusted input. Do not execute message-supplied HTML or scripts. Never attach a Discord authorization header to third-party media, CDN, or upload destinations; re-evaluate the exact destination on every redirect.

Preserve account isolation across credentials, cache records, media, notifications, and diagnostics. Redact secrets and message content by default. Any diagnostic export must have a user-visible preview. Do not describe local cache presence as proof of current authorization or guaranteed access to removed content.

Changes involving authentication, credential handling, redirects, local IPC, uploads, diagnostics, capture, or extension execution must include an explicit threat-model update or explain why the existing model still applies. See [AuthThreatModel.md](docs/AuthThreatModel.md).

## Tests and validation

Every behavior change should include or update deterministic tests where practical. The existing suite covers Snowflake wire preservation, tolerant Gateway values, deterministic backoff, authentication lifecycle transitions, redacted credential descriptions, credential removal, cache isolation, retention bounds, drafts, pending sends, credential-destination checks, redirect re-evaluation, and rate-limit parsing.

Transport and persistence work should use injected clocks, URLProtocol or WebSocket fakes, split and multi-event Gateway fixtures, cancellation cases, rate-limit responses, reconnects, edits, deletions, permission changes, account switching, and channel removal. Tests must not contact Discord unless a separately documented, manually supervised integration test explicitly requires it.

Prefer deterministic fixtures and injected clocks over sleeps or timing assumptions. If a test needs a new substitute, keep it in test support or the relevant test target rather than introducing production-only seams without a clear use.

Real-account authentication, voice, video, screen capture, and release tests require a written record of the macOS, Xcode, dependency, and client versions used. Do not present a successful stock WebRTC demo, capture-only prototype, or bot implementation as proof of Discord client interoperability.

## Native UI and accessibility

The current application uses SwiftUI for its structure and renders the message timeline with `ScrollView` and `LazyVStack`. The composer uses an AppKit `NSTextView` bridge for native selection, undo, text input methods, and keyboard behavior. Keep contributions accurate to this current implementation rather than describing planned controls as already shipped.

The intended high-volume timeline design is an AppKit `NSCollectionView` with a diffable data source, to be adopted only when the implementation and performance evidence justify it. Changes should preserve a clear boundary between the current SwiftUI presentation and that future migration. In either design, preserve keyboard navigation, selection, undo, text input methods, and stable reading position during pagination.

UI changes should be checked with a large fabricated history and should not force a reader to the newest message while older content is being viewed. Validate keyboard-only use, VoiceOver labels and actions, reduced-motion behavior, and Russian and English input methods. Include screenshots or a short recording in a pull request when visual or interaction behavior materially changes.

## Dependencies and generated files

The manifests are intentionally dependency-free at this stage. Before adding a dependency, explain why a system framework or existing project code is insufficient, pin an exact release or revision, review the license and transitive dependencies, and document reproducible build steps. Do not track floating main branches in production.

Do not hand-edit `NativeDiscordClient.xcodeproj`; update the reviewed `project.yml` and regenerate the project with XcodeGen when needed. The generated `*.xcodeproj` is gitignored and must remain untracked. Do not add downloaded native libraries, arbitrary scripts, or unreviewed code execution systems. Planned technologies such as GRDB, libwebrtc, libdave, ScreenCaptureKit, and Sparkle still require compatibility, build, and license review before adoption.

## Commits and pull requests

Keep commits and pull requests focused. Use concise imperative commit subjects, describe the reason for the change in the body when it is not obvious, and keep unrelated formatting or cleanup out of feature work.

A pull request should state what changed, why it belongs in the current phase, how it was tested, and any remaining limitations. Include the exact commands run and identify tests that were manual, fabricated, or unavailable. For UI work, attach before-and-after screenshots or a short recording. For protocol or security work, link the relevant checked-in design note and clearly distinguish official documentation from unofficial observations.

Never include tokens, private account data, private package URLs, captured message content, production logs, or unreviewed generated artifacts in a commit or pull request. Review project configuration changes in `project.yml`; do not commit generated Xcode projects.

AI-assisted work must remain bounded by a clear task, fixture set, and acceptance criteria. Agents may work on isolated UI, protocol-model, persistence, rendering, or test-support tasks, but must not receive real credentials. Authentication, media bridges, and release security require deliberate human review and evidence from the commands and manual tests actually run.

## License

This project is licensed under the GNU General Public License, version 3.0. Contributions and redistribution must preserve the terms in [LICENSE](LICENSE). New dependencies, including any future media or cryptography components, require separate license and compatibility review before release use.
