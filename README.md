# ScreenMate

A native macOS desktop assistant that lives in a small floating widget. Talk to it
or type to it, point it at your screen, and get answers without leaving what you
were doing.

Built with Swift 5.9, SwiftUI and AppKit. macOS 13 (Ventura) or later.

> **Status: unbuilt source.** This repository was written in a Linux container
> with no Swift toolchain, so **nothing here has been compiled or run.** Every
> feature described below is implemented in source, but "implemented" is not
> "verified". See [Verification status](#verification-status) for exactly what
> that means before you trust any of it.

---

## What it does

- **Floating widget.** A 52pt puck that sits above other windows, follows you
  across Spaces and over full-screen apps, and remembers where you put it.
- **Type or talk, equally.** A text field and a microphone button of the same
  size, side by side. Push-to-talk or hands-free, with live partial transcription.
- **Screen understanding.** Capture the front window, a whole display, or drag
  out a region. See the picture before it is sent. On-device OCR feeds the text to
  the model alongside the image.
- **Spoken replies.** `AVSpeechSynthesizer` reads answers aloud, with markdown
  stripped so it does not say "hash hash Summary". Start talking and it stops.
- **Web research.** Optional, off by default, through a documented search API.
  Sources are shown under the reply.
- **Actions, with consent.** Copy to clipboard, open a page, save a note — each
  one shows you the exact content and waits for you to allow it.
- **Provider-agnostic.** Anthropic and OpenAI ship with it; an OpenAI-compatible
  base URL points it at a local model. An offline demo provider lets you try the
  whole interface with no API key.

## Quick start

```bash
git clone <this repo>
cd Voice-OS-project

# Build ScreenMate.app and sign it so macOS will grant it permissions.
./Scripts/build-app.sh release

open dist/ScreenMate.app
```

On first launch you get a four-page privacy walkthrough, then the widget appears
in the bottom-right corner. Click it to expand.

Without an API key, ScreenMate runs against a built-in **offline demo provider**
whose replies are canned text — enough to exercise voice, capture, streaming and
text-to-speech, and clearly labelled as a demo so you cannot mistake it for a
model.

### Why a script instead of `swift run`

`swift run ScreenMate` produces a bare executable, and macOS will not grant
Screen Recording, Microphone or Speech Recognition to one: TCC keys its decisions
on a bundle identifier and a code signature. `Scripts/build-app.sh` assembles a
real `.app` around the binary with `Resources/Info.plist`, then signs it ad-hoc.

Pass a Developer ID to produce a build that runs on another Mac:

```bash
SCREENMATE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./Scripts/build-app.sh release
```

### Building in Xcode

`open Package.swift` works for editing, and you can run the test suites from
Xcode. To *run* the app with working permissions you still want the script, or an
Xcode app target that uses `Resources/Info.plist` and
`Resources/ScreenMate.entitlements`.

## Configuring an AI provider

Open **Settings › Provider** (the `…` menu in the panel header, or ⌘, from the
menu bar item).

| Provider | Models offered | Where to get a key |
|---|---|---|
| Anthropic | Claude Opus 5, Sonnet 5, Haiku 4.5 | <https://console.anthropic.com/settings/keys> |
| OpenAI | GPT-4o, GPT-4o mini, GPT-4.1 | <https://platform.openai.com/api-keys> |
| Demo (offline) | — | no key needed |

1. Pick a provider and a model. Models that can see images are marked
   *sees images*; a text-only model still works, and a capture falls back to its
   OCR text rather than silently doing nothing.
2. Paste the key and press **Save**. It goes into the **login Keychain** as a
   generic password under the service `com.screenmate.ScreenMate`. It is never
   written to `UserDefaults`, a plist, a log line, or a saved conversation, and
   the text field is cleared the moment it is stored.
3. Press **Test connection** to send one 16-token request and confirm the key and
   model actually work, rather than finding out mid-conversation.

### Pointing at a local model

`OpenAIChatProvider` takes a `baseURL`, so anything speaking the Chat Completions
wire format works. To add Ollama or LM Studio as a visible provider, add one entry
to `ProviderCatalog.standard` in
`Sources/ScreenMateCore/AI/ProviderCatalog.swift`:

```swift
Entry(
    descriptor: ProviderDescriptor(
        id: "local",
        displayName: "Local model",
        requiresAPIKey: false,
        models: [AIModel(id: "llama3.2-vision", displayName: "Llama 3.2 Vision", supportsVision: true)],
        apiKeyHelpURL: nil,
        privacyNote: "Requests stay on this Mac."
    ),
    factory: { _, transport in
        OpenAIChatProvider(
            apiKey: "",
            transport: transport,
            baseURL: URL(string: "http://localhost:11434")!,
            id: "local",
            displayName: "Local model",
            requiresAPIKey: false,
            models: [AIModel(id: "llama3.2-vision", displayName: "Llama 3.2 Vision", supportsVision: true)]
        )
    }
)
```

There is a test covering exactly this shape
(`OpenAIProviderTests.testCustomBaseURLEnablesLocalModels`).

### Web search

**Settings › Web**, off by default. Brave Search and Tavily are wired up; both
need their own key, stored in the Keychain separately from the model key. With web
access off, the `web_search` tool is not even offered to the model, and a
hand-rolled attempt to use it fails with "Web access is turned off".

ScreenMate only calls documented search APIs. It does not crawl or scrape pages,
so there is no robots.txt to respect on its side and no rate-limit loop to run
away with: a 429 surfaces as an error with the retry delay, and nothing retries
automatically.

## macOS permissions

Every permission is optional. Typing to a text model works with none of them.

| Permission | What stops working without it | When macOS asks |
|---|---|---|
| **Microphone** | Voice input | First time you press the mic button |
| **Speech Recognition** | Voice input | Same |
| **Screen Recording** | Screen awareness | First capture, or from Settings › Privacy |
| **Accessibility** | Window titles, and the sensitive-app guard's title check | Only if you ask for it |

Each has a usage string in `Resources/Info.plist` that says what is captured and
when, because that system prompt is often the only privacy notice anyone reads.

**Screen Recording needs a relaunch.** macOS caches the answer for the running
process, so after you allow it you must quit and reopen ScreenMate. The app says
this rather than appearing broken.

If macOS refuses to capture after you granted permission — usually a stale TCC
entry from an earlier unsigned build:

```bash
tccutil reset ScreenCapture com.screenmate.ScreenMate
```

Permissions are re-read on every app activation, so revoking one mid-session is
noticed: the microphone closes, any held capture is dropped, and you get a banner
explaining what happened.

## Using it

### Keyboard

| Shortcut | Action |
|---|---|
| ⌥⌘Space | Show / hide the panel |
| ⌥⌘V | Start or stop voice input |
| ⌥⌘S | Drag out a region to analyse |
| Return | Send |
| Esc | Cancel the innermost thing: a confirmation, a capture preview, a recording, a reply in progress — then collapse the panel |

All three globals are rebindable in **Settings › General**. They use Carbon's
`RegisterEventHotKey`, which works without Accessibility permission; if another
app already owns a combination, Settings says so instead of silently failing.

### Things to ask it

- "What am I looking at?"
- "Explain this error."
- "Summarise this page."
- "Rewrite this professionally."
- "What should I do next?"

For anything about your screen, capture first (or ask it to, which it will ask
your permission for).

## Privacy

The short version: **nothing is captured, recorded or sent until you ask.**

- **Screen awareness is off by default,** and needs a *second* switch —
  "Send screen content to the AI provider" — before any pixels can leave the Mac.
  Both are checked in one place, `AppSettings.mayShareScreenWithProvider`, which
  `PromptBuilder` consults as the single choke point. There are tests asserting
  that each switch alone attaches nothing.
- **You see every capture before it is sent,** with its size, its source, where it
  is going, and what the redactor removed.
- **Visible indicators.** A red dot on the widget means the microphone is open. An
  orange dot means the screen is being read. They are driven by
  `AssistantActivity.isCapturingAudio` / `.isReadingScreen`, which are true only
  while it is really happening — there are tests pinning that down.
- **Screenshots never reach disk.** Captures live in a `ScreenContextBox` that is
  emptied when the turn ends, when you discard, when screen awareness goes off,
  and on quit. Saved transcripts record *that* an image was attached, its size and
  its source — never the image.
- **Automatic redaction** of API keys, private key blocks, JWTs, `password:`
  assignments, Luhn-valid card numbers, IBANs and national ID numbers, applied to
  OCR text before it is sent. Pattern-based and therefore best-effort: it will
  miss secrets that do not look like secrets, and it does **not** alter the
  picture. That is why the preview exists.
- **A sensitive-app guard** refuses to capture 1Password, Bitwarden, Keychain
  Access and friends, and windows whose titles mention passwords, card numbers or
  recovery phrases. It tells you why rather than capturing quietly.
- **API keys in the Keychain**, accessible only while the Mac is unlocked.
- **Anything that changes your Mac asks first,** showing the specific content —
  this URL, this text. Declining is the default if a prompt is ever dropped.
- **No analytics, no telemetry, no network calls you did not cause.**
- **Delete everything** in Settings › Privacy: conversations, notes and every API
  key, in one action.

`docs/PRIVACY.md` has the full data-flow table.

## Architecture

```
Sources/
  ScreenMateCore/          pure Foundation — no AppKit, no Apple UI frameworks
    Models/                ChatMessage, Conversation, AppSettings, AppError, ScreenContext, JSONValue
    AI/                    provider protocols, Anthropic, OpenAI, demo, PromptBuilder, ChatEngine
    Networking/            HTTPTransport seam, SSE parser
    Search/                search protocol, Brave, Tavily, recency heuristic
    Privacy/               redactor, sensitive-app policy
    Tools/                 tool protocol, built-in tools, ToolRunner + confirmation gate
    Storage/               settings, secrets, conversations, exporter
    StateMachines/         VoiceSessionMachine, ScreenCaptureMachine
    Ports/                 clipboard / URL / note / capture / speech protocols

  ScreenMateKit/           everything that needs an Apple framework
    App/                   AppEnvironment (DI graph), app delegate, menu bar
    Core/Permissions/      PermissionCenter over a PermissionProbing seam
    Core/Audio/            SFSpeechRecognizer transcriber, AVSpeechSynthesizer speaker, CoreAudio devices
    Core/ScreenCapture/    ScreenCaptureKit service, region overlay, Vision OCR, image encoder
    Core/Storage/          Keychain, AppPaths, login item
    Core/Tools/            AppKit port implementations, capture_screen tool
    Core/Hotkeys/          Carbon global shortcuts
    Features/              Chat, Voice, ScreenAwareness, Settings, Onboarding, Widget
    UI/                    design system

  ScreenMate/              @main entry point (~20 lines)

Tests/
  ScreenMateCoreTests/     runs on any platform with a Swift toolchain
  ScreenMateKitTests/      macOS only
```

The split is the point. `ScreenMateCore` has no UI framework dependency, which is
what makes the provider parsing, the privacy rules, the storage, the tool gate and
the two state machines genuinely unit-testable — and it means `Package.swift`
declares the macOS targets only when the manifest is evaluated on macOS, so
`swift test --filter ScreenMateCoreTests` works in Linux CI.

### The pieces that carry the design

**`PromptBuilder`** (Core) is the only thing that can attach a screenshot. It is a
pure function from (conversation, screen context, settings) to (system prompt,
turns), and it reports back exactly what it attached so the UI can disclose it
after the fact. Putting that rule in one pure function is why it can be tested
rather than asserted in a comment.

**`ChatEngine`** (Core) runs one turn: build prompt → stream → run tools → feed
results back → repeat, bounded at four rounds. It emits an `AsyncStream<Update>`
of activity changes, text deltas, tool records, citations and failures. Because
every dependency is injected, a test drives a complete tool round-trip with no
network, no AppKit and no clock.

**`ToolRunner`** (Core) is the consent gate. `ToolSideEffect` is declared next to
each tool and checked in exactly one place. A runner built without a confirmer
declines every mutating tool — the safe default is wired in, not remembered.

**Two state machines** (Core) hold the orderings that are otherwise where the bugs
live: a stop arriving before the engine started, a final transcript after a cancel,
a capture approved after screen awareness was switched off. `VoiceController` and
`ScreenAwarenessController` only perform the effects the machines return.

**`AppEnvironment`** (Kit) is the dependency graph. Settings live here as the
single `@Published` source of truth, persisted on every change, with a
lock-protected snapshot so the capture actor can read them without a main-actor
hop.

MVVM throughout: view models are `@MainActor ObservableObject`s with injected
services; views own no logic. Nothing has a singleton.

### Adding a backend

| To add | Implement | Register in |
|---|---|---|
| A chat/vision model | `ChatModelProviding` | `ProviderCatalog.standard` |
| A search engine | `WebSearchProviding` | `SearchCatalog.standard` |
| A speech recogniser | `SpeechTranscribing` | `AppEnvironment.init` |
| A TTS engine | `SpeechSpeaking` | `AppEnvironment.speaker` (see limitations) |
| A tool | `AssistantTool` | `ToolRunner.standardTools` |
| A conversation store | `ConversationStoring` | `AppEnvironment.makeConversationStore` |
| A secret store | `SecretStoring` | `AppEnvironment.init` |

## Testing

```bash
make test        # ScreenMateCore — runs anywhere with a Swift toolchain
make test-all    # everything, macOS only
```

254 test cases across two suites (185 in Core, 69 in Kit, all unrun — see
[Verification status](#verification-status)). What they cover:

**Core** — SSE parsing (multi-line data, heartbeats, truncated streams); Anthropic
and OpenAI request encoding and response decoding, including tool arguments
arriving in fragments; error mapping (401 → invalid key, 404 → model unavailable,
429 → rate limited with `Retry-After`); provider switching; every `AppError` case
having a message and a next step; redaction (each pattern, plus a Luhn check that
a long order number is *not* redacted); the sensitive-app policy; the tool
confirmation gate (including that the default confirmer denies, and that an
approved-and-then-failed tool comes back as a model-readable error rather than a
thrown exception); `open_url` refusing `file://`; `PromptBuilder`'s privacy rule
from every angle; `ChatEngine`'s tool loop, its bound, and its refusal to drop a
capture silently; settings round-trip and tolerant decoding of an older file;
conversation persistence, file permissions, pruning and deletion; export in three
formats; both state machines including the ordering traps.

**Kit** — `PermissionCenter` against a fake probe, including mid-session
revocation being reported once; `VoiceController` (mic stays shut until permission
is granted, cancel never submits, a late transcript after cancel is dropped,
revocation closes the mic); `ScreenAwarenessController` (no capture while awareness
is off, preview gating, sensitive-app block, release after use); the image encoder
downscaling a 5K capture while preserving aspect ratio; `ToolConfirmationCenter`'s
continuation bridge, including that a dropped prompt declines; markdown stripping
for speech; Carbon modifier translation; and `AssistantViewModel` end-to-end
against the offline demo provider — send, stream, persist, title, clear, stop,
attach a capture and see it released.

Where a macOS API cannot be faked (`SFSpeechRecognizer`, `ScreenCaptureKit`,
`AVSpeechSynthesizer`, the real Keychain), the seam is the protocol and the test
sits on this side of it. Those APIs themselves are exercised only by running the
app.

## Verification status

I am not going to tell you this works when I have not run it.

**Written and reviewed, not executed:**
- Nothing in this repository has been compiled. There was no Swift toolchain in
  the environment it was written in, and the network policy blocked
  `download.swift.org`, so one could not be installed.
- The test suites have therefore never been run. They are written against the
  real APIs and should be a fair reflection of behaviour once they compile, but
  *expect to fix compile errors on the first build.* Type-level mistakes are the
  likely kind; the logic has been reviewed closely.
- Any macOS behaviour that only shows up at runtime is unverified by definition:
  TCC prompt wording and timing, `SCScreenshotManager` output on mixed-DPI
  multi-monitor setups, panel behaviour over full-screen apps and across Spaces,
  Carbon hot-key conflicts, on-device speech availability per language, and how
  `AVSpeechSynthesizer` handles the stripped text.

**Deliberately not implemented** (so you do not go looking):
- No conversation list UI. Transcripts are saved and `load(conversationID:)`
  exists, but nothing calls it yet — you get the current conversation and export.
- No drag-and-drop or file attachment. `MessageAttachment.Kind` has cases for it;
  no drop zone is wired up.
- No app icon. The menu bar item uses an SF Symbol.
- No localisation. English strings are inline.

## Current limitations

- **A mid-turn `capture_screen` cannot reach the model as an image.** Image blocks
  are fixed when a turn starts, so a capture the model asks for comes back to it
  as OCR text, and the picture is attached for your *next* message. The UI shows
  it immediately. Fixing this properly means restarting the turn with the new
  image, which is a behaviour change worth doing deliberately.
- **Streaming re-renders the whole transcript.** Each token mutates the published
  `Conversation`. Fine for a 380pt panel and a few dozen messages; it will need
  per-message state objects before it is fine for hundreds.
- **History is truncated, not summarised.** Past 24 messages, the oldest are
  dropped.
- **Redaction does not touch the image.** Only the OCR text is scrubbed. A key
  visible in the screenshot is visible to the model. The preview is the real
  defence.
- **The app is not sandboxed.** See the comment in
  `Resources/ScreenMate.entitlements` for why, and what shipping through the App
  Store would cost.
- **TTS is wired concretely.** `SpeechSpeaking` exists and `AVSpeechSpeaker`
  conforms, but `AppEnvironment` holds the concrete type because Settings needs
  voice enumeration and a completion callback that are not on the protocol yet.
- **Window titles need Accessibility.** Without it, captures are labelled by app
  name only, and the sensitive-app guard falls back to bundle identifiers alone.
- **No retry button wiring.** `MessageFailure.isRetryable` is computed and
  displayed, but `MessageRowView`'s retry action is passed `nil`.
- **macOS 13 uses deprecated capture APIs.** `SCScreenshotManager` is macOS 14+;
  on 13 the service falls back to `CGDisplayCreateImage` /
  `CGWindowListCreateImage`, which work but emit deprecation warnings.

## Roadmap

**Next** — the things whose absence you will notice first:
1. A conversation list, using the `ConversationStoring` API that already exists.
2. Retry on a failed turn.
3. Restart-the-turn-with-the-image for `capture_screen`.
4. Drag-and-drop images and text files onto the panel.
5. Per-message view models so long transcripts stay smooth.

**Then:**
6. Follow-up captures in a conversation without re-approving each one, with a
   visible session indicator and a hard time limit.
7. Rolling summarisation instead of truncation.
8. A real app icon, and a notarised release build.
9. Whisper (on-device, via `SpeechTranscribing`) as an alternative recogniser.
10. Streaming TTS that starts speaking before the reply finishes.

**Later, and only carefully:**
11. More tools: draft an email into a Mail compose window, extract a table to CSV,
    open an app. Each one needs its own confirmation copy, and each one widens the
    blast radius — the confirmation gate exists precisely so this can grow without
    becoming dangerous.
12. Accessibility-API reading of the focused element, as a cheaper and more
    precise alternative to a screenshot for text-heavy windows.
13. Optional local-only mode: a local model plus on-device speech, with the
    network switched off entirely.

## Licence

None chosen yet. Treat it as all rights reserved until one is added.
