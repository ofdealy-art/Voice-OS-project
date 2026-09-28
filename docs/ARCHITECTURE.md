# ScreenMate — architecture notes

The README has the map. This file records the decisions that are not obvious from
reading the tree, and why they went the way they did.

## Two targets, and why it matters

`ScreenMateCore` imports nothing but Foundation. `ScreenMateKit` imports AppKit,
SwiftUI, AVFoundation, Speech, ScreenCaptureKit, Vision, Security, Carbon and
ServiceManagement.

That line was drawn for testability rather than tidiness. The interesting logic in
a desktop assistant is: did we correctly decide not to send this screenshot, did we
reassemble this fragmented tool call, did a cancel arriving after a stop drop the
transcript, does a declined tool still let the turn finish. None of that needs a
window, and all of it is hard to test if it sits inside a view.

`Package.swift` declares the macOS targets inside `#if os(macOS)`, so
`swift test --filter ScreenMateCoreTests` runs in Linux CI.

## Protocol seams, in the order they earn their keep

**`HTTPTransport`** — the seam that makes provider tests real. Both shipping
providers parse recorded SSE byte streams in tests; no sockets, no network flake.

**`ChatModelProviding`** — one protocol for chat and vision, because every current
vision model is also a chat model. Per-model capability lives in
`AIModel.supportsVision`, so the app can refuse to attach an image to a text-only
model instead of discovering it as a 400.

**`AssistantTool` + `ToolSideEffect`** — the consent gate. Declaring the side
effect next to the tool and enforcing it in one place (`ToolRunner`) is what stops
"does this need confirming?" from being re-decided at each call site.

**`PermissionProbing`** — TCC behind a protocol. `PermissionCenter` is then
testable, including the case that matters most: a permission granted at launch and
revoked while the app runs.

**`SpeechTranscribing` / `SpeechSpeaking`** — both `@MainActor`, because their
shipping implementations must be. A fake transcriber driven by the test is how the
voice lifecycle gets covered without a microphone.

**`ScreenCapturing`** — declared in Core with a framework-free `ScreenRegion`
rather than `CGRect`, so Core never imports CoreGraphics.

**Ports (`ClipboardWriting`, `URLOpening`, `NoteWriting`)** — how Core's tools act
on the world without importing AppKit.

## Where the rules live

Each of these is deliberately in exactly one place, because each was a rule that
would otherwise get re-implemented inconsistently:

| Rule | Enforced in |
|---|---|
| A screenshot may only be attached when both privacy switches are on | `PromptBuilder.build` |
| A mutating tool may not run without approval | `ToolRunner.run` |
| Nothing may be captured while screen awareness is off | `ScreenCaptureMachine.handle` **and** `ScreenCaptureService.capture` (belt and braces) |
| The microphone may not open before permission is granted | `VoiceSessionMachine.handle` |
| A cancelled recording may never be submitted | `VoiceSessionMachine.discardNextTranscript` |
| Pending capture pixels have one owner and are always released | `ScreenContextBox` + `.discardImage` effects |
| Every user-visible failure has a next step | `AppError.recoverySuggestion`, with a test that walks every case |

## State machines instead of view-model flags

`VoiceSessionMachine` and `ScreenCaptureMachine` are pure `struct`s: `(state,
event) -> (state, [effect])`. The controllers perform effects and nothing else.

This was not architecture for its own sake. The bugs in voice and capture UI are
almost all ordering bugs — a stop before the engine started, a final transcript
after a cancel, a preview approved after the user switched screen awareness off, a
double-start leaving an orphaned audio tap. Those are trivial to test as
transitions and very hard to test through a view.

## Concurrency

- View models and UI-touching services are `@MainActor ObservableObject`.
- `ScreenCaptureService` is an `actor`: capture and encoding are heavy and must not
  block the main thread. It reads settings through `SettingsSnapshot`, a
  lock-protected copy, because it cannot reach into the main-actor environment.
- Providers return `AsyncThrowingStream`; `ChatEngine` returns `AsyncStream<Update>`.
  Cancellation propagates through `onTermination`, so pressing Stop really stops
  the HTTP request.
- Delegate callbacks from non-`@MainActor` frameworks (`AVSpeechSynthesizerDelegate`,
  `NSMenuDelegate`) are implemented `nonisolated` and hop explicitly.
- A `@MainActor` class's `deinit` is non-isolated and cannot touch isolated state,
  so `PermissionCenter` puts its notification token in a small non-isolated box
  that cleans itself up, and `HotKeyManager` has no `deinit` at all.

## Why a plain `NSApplication` and not SwiftUI's `App`

The product is a borderless, non-activating `NSPanel` that must not steal focus
from the app you are actually working in, must float above other windows, must
follow you across Spaces and over full-screen apps, and must resize between two
fixed sizes without appearing to jump. Every one of those is a fight with
`WindowGroup` and a one-liner on `NSPanel`.

`FloatingPanel` uses `[.nonactivatingPanel, .titled, .fullSizeContentView]` with a
hidden title bar: `.nonactivatingPanel` keeps app focus where it was,
`canBecomeKey` is overridden to `true` so the text field still takes keystrokes,
and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
handles Spaces and full-screen.

## Multi-monitor and Retina

Three coordinate systems meet in region selection, which is where this normally
goes wrong:

- AppKit: origin bottom-left of the primary screen, points.
- CoreGraphics / ScreenCaptureKit: origin top-left of the primary screen, points.
- Captured images: pixels, scaled by the display's `backingScaleFactor`.

`NSScreen.frameInCoreGraphicsCoordinates` converts the first to the second.
`RegionSelectionWindow.globalRect(from:)` flips a drag from view coordinates into
global CoreGraphics coordinates. `ScreenCaptureService.captureRegion` then picks the
display holding most of the rect, captures that display whole, and crops **in that
display's pixel space** — which is what makes it correct when two monitors have
different scale factors.

Captures are downscaled to a 1568px longest edge before encoding, both to fit
provider size limits and because a 14-megapixel screenshot reads no better to a
vision model than a 2-megapixel one.

## The `capture_screen` compromise

The model can ask to look at the screen, and that request goes through the same
confirmation gate as any other consequential action. But image blocks for a request
are fixed when the turn starts, so what the tool returns to the model is the
on-device OCR text; the picture is attached for the user's *next* message and shown
in the UI immediately.

The alternative — restart the turn with the new image — changes the shape of a turn
and is worth doing deliberately rather than as a side effect. It is on the roadmap.
The tool's docstring says exactly this, so a future reader is not misled.
