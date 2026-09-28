# ScreenMate — what leaves your Mac

This is the complete data-flow picture. It is written to be checkable against the
source, not to reassure.

## Defaults

| Setting | Default | Why |
|---|---|---|
| Screen awareness | **off** | Nothing should be able to read your screen because you installed something. |
| Send screen content to the AI provider | **off** | A second, separate switch, so "let it look" and "let it upload" are different decisions. |
| Web access | **off** | Search queries are their own disclosure to a third party. |
| Save conversations | on | Local only, with a retention setting and a delete button. |
| Read text from captures on this Mac (OCR) | on | Runs locally through Vision; nothing leaves for this step. |
| Remove credentials from that text | on | Best-effort redaction before anything is sent. |
| Skip password managers | on | Refuses rather than captures. |
| Always show the capture before sending | on | You see the picture before it goes. |
| Analytics | **off, and there is no code to turn on** | |

## What goes where

### To your AI provider, when you press Send

- The text you typed or spoke.
- Recent messages from the current conversation (up to 24).
- **A screenshot — only if** you captured one, approved the preview, *and* both
  screen switches are on. Checked in one place:
  `AppSettings.mayShareScreenWithProvider`, consulted by `PromptBuilder`.
- Text read from that screenshot by Vision on your Mac, with recognised
  credentials replaced by `[redacted]`.
- The current local date, time and time zone.
- Which tools are available, and the results of any you approved.

The provider is whichever you configured. The destination host is stated under the
API key field in Settings, and again in the capture preview.

### To your search provider, only when web access is on

- The search words the model chose. Shown to you in the status line while the
  search runs, and the sources appear under the reply.
- **Never your screen, never your screenshot, never your conversation.**

### Never off this Mac

- **API keys.** macOS login Keychain, service `com.screenmate.ScreenMate`,
  `kSecAttrAccessibleWhenUnlocked`. Never in `UserDefaults`, a plist, a log, or a
  transcript.
- **Screenshots as files.** Captures are held in a `ScreenContextBox` in memory
  and dropped when the turn ends, when you discard, when screen awareness is
  switched off, or when the app quits. `MessageAttachment` — the only thing
  persisted — has no image field.
- **Your voice, where your Mac can transcribe locally.** "Prefer on-device
  transcription" is on by default and used whenever
  `SFSpeechRecognizer.supportsOnDeviceRecognition` is true for your language.
  Otherwise Apple's speech service transcribes it, which is the same path as
  system dictation.
- **Analytics.** There are none.

## What is stored on disk

`~/Library/Application Support/ScreenMate/`, directories `0700`, files `0600`:

- `Conversations/<uuid>.json` — message text, timestamps, citations, tool records,
  and attachment *metadata* (kind, size, pixel dimensions, source description,
  and a note of what was redacted). OCR text is stored only when both "Save
  conversations" and OCR are on.
- `Notes/` — anything you approved `create_note` to write.

Retention is your choice: until quit, 7 days, 30 days, or until you delete.
Pruning runs at launch and whenever you change the setting.
**Settings › Privacy › Delete everything** removes all of it plus every Keychain
item, in one action.

## Indicators

- **Red dot on the widget** — the microphone is open. Driven by
  `AssistantActivity.isCapturingAudio`, which is true only for the listening and
  transcribing states. Tests assert no other state can claim it.
- **Orange dot** — the screen is being read. Driven by
  `ScreenCaptureState.isCapturing`, true only while the overlay is up or a capture
  is in flight.
- **Menu bar icon** changes to a microphone or an eye for the same reasons.
- **The eye button** in the panel header pauses screen awareness instantly and
  discards anything held.

## Consent for actions

`copy_to_clipboard`, `open_url`, `create_note` and `capture_screen` are declared
`ToolSideEffect.mutating`. `ToolRunner` will not run any of them without a `true`
from a `ToolConfirming`, and a runner built without one **declines everything** —
the safe default is in the code, not in a convention. The sheet shows the actual
argument: the URL, the text, the note title. Dismissing it counts as declining.

`open_url` refuses anything that is not `http` or `https`, so it cannot be steered
into `file://` or a custom handler.

## Redaction: what it does and does not do

Applied to OCR text before sending. Patterns: OpenAI / Anthropic / Stripe / GitHub
/ Slack / Google / AWS key shapes, PEM private key blocks, JWTs, `Authorization:`
headers, `password:` / `secret:` / `access_token:` assignments, Luhn-valid card
numbers, IBANs, and `NNN-NN-NNNN` national ID numbers.

It **will** miss a secret that does not look like one. It does **not** modify the
screenshot — a key visible in the picture is visible to the model. The preview,
and the fact that capture is opt-in and per-request, are the real protections. The
capture preview says so in as many words.

## The sensitive-app guard

Refuses to capture 1Password, Bitwarden, LastPass, Dashlane, Enpass, KeePassXC,
Keychain Access, Apple Passwords and the Stripe dashboard by bundle identifier, and
any window whose title mentions a password, passphrase, private or secret key, seed
or recovery phrase, authenticator, one-time code, card number, CVV, social security
or two-factor. It tells you what it refused and why.

Title matching needs Screen Recording (for `CGWindowListCopyWindowInfo`); without
Accessibility the bundle-identifier check still applies. This is a guard against
accidents, not an adversary.

## Threat model, honestly

ScreenMate protects you from **your own slips** — capturing a password manager by
reflex, a key in a terminal scrollback, forgetting the screen switch is on. It
gives you an audit trail of what was sent and a one-action delete.

It does **not** protect you from a malicious AI provider (you gave them the
screenshot), from malware already on your Mac (nothing here is a sandbox), or from
a screenshot whose sensitive content is an image rather than text. The app is not
sandboxed; see `Resources/ScreenMate.entitlements` for the reasoning.
