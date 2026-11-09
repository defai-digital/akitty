# Siri and Shortcuts on macOS 27.2

The native Apple Silicon app requires macOS 27.2 or later. Siri integration is
built and tested with stable Xcode 27.2 and macOS 27.2. Spoken Siri
qualification is a separate device check described below.

The macOS 27.3 Siri AI preview implementation has been removed. There are no
preview build flags, custom tool annotations, or app skills. Later OS versions
can meet the minimum deployment requirement, but 27.3-specific integration and
behavior are outside the current qualification scope. Installing a beta SDK or
upgrading the OS is not part of the macOS 27.2 setup.

AkiTTY includes ten App Intents and matching App Shortcuts. The shortcuts ship
with the app; users do not need to build their own workflow first. The bundled
trigger phrases are in English. System language, region, device support, and
Siri settings affect discovery and speech recognition. This functionality is
in the current source tree; check [unreleased changes](releases/unreleased.md)
and the downloaded release's notes before expecting it in a published build.

## Get started on macOS 27.2

1. Install a build containing this integration and open **Akitty.app** once.
   When building from source, use `bash scripts/build-app.sh debug` and open
   `build/Akitty.app`. The packaging script includes the required metadata;
   launching a standalone executable from `swift build` is not the setup path.
2. Enable Siri in macOS. Open the Shortcuts app and look for AkiTTY's ten
   actions. You can use these defaults directly or compose a workflow that
   passes a terminal reference from List Terminals to another action.
3. Try “List terminals in AkiTTY” or “Open a new terminal in AkiTTY.” Use the
   English phrases below; recognition depends on your Siri configuration.
4. Try “Request a command in AkiTTY,” choose a current terminal, and enter `pwd`.
   Review the target and exact command in AkiTTY's approval sheet. Deny first,
   then make a new request and explicitly approve it to check dispatch.

Siri and Shortcuts requests do not require **Enable Local Agent Requests**.
That setting controls the local socket interface used by clients such as
`akitty-agent`. Command approval still applies to every Siri or Shortcuts request.

## Available actions

| Action | Example Siri phrase | Behavior |
| --- | --- | --- |
| New Terminal | “Open a new terminal in AkiTTY” | Creates a window with the configured shell and directory; returns its pane reference. |
| Open Folder | “Open a folder in AkiTTY” | Asks for an existing folder and opens a window there; returns its pane reference. Never runs a command. |
| New Tab | “New tab in AkiTTY” | Adds a tab to a chosen window, or to the key window when none is chosen. Creates a window when no terminal window exists. The tab inherits the focused pane's directory. |
| Split Pane | “Split the terminal in AkiTTY” | Splits a chosen pane's tab into two panes; a tab holds at most eight. Returns the new pane reference. |
| Show Quick Terminal | “Show the quick terminal in AkiTTY” | Shows the persistent quick terminal; repeating the request keeps it visible. |
| Agent Overview | “Show agents in AkiTTY” | Shows reported activity and input ownership across windows and panes. |
| List Terminals | “List terminals in AkiTTY” | Returns current panes and speaks a brief list of names, including the total count. Runs without bringing AkiTTY forward. |
| Terminal Status | “Get terminal status in AkiTTY” | Prompts for a pane and reads fresh reported activity, input ownership, and shell readiness. Runs without bringing AkiTTY forward. |
| Focus Terminal | “Focus a terminal in AkiTTY” | Prompts for a pane and brings its window and tab forward. |
| Request Command | “Request a command in AkiTTY” | Prompts for a pane and exact command, then opens the native approval sheet. |

For actions with required parameters, Siri or Shortcuts asks for the missing
values. Complex shell quoting and punctuation are best entered in Shortcuts
or reviewed carefully in the approval sheet. The App Shortcuts phrases include
the app name. A terminal reference is valid only while that pane remains open
in the same app instance; saved shortcuts must query or select current panes.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| AkiTTY actions are missing | Confirm the installed app contains this integration, open the app bundle, then reopen Shortcuts. For source builds, use the packaging script above. |
| Shortcuts works but a spoken phrase does not | Check that Siri is enabled and that its language matches the bundled English phrases. Spoken recognition remains a separate device check. |
| A saved terminal is no longer available | Run List Terminals or choose a current pane again. Pane references expire when a pane closes or the app restarts. |
| A command request is rejected | The chosen pane needs an idle integrated shell and must remain open. Finish or cancel any other pending request, then review a new request in AkiTTY. |
| A command was dispatched but the outcome is unclear | Inspect the terminal before issuing another command. Dispatch does not prove successful completion; avoid automatic retries. |

If discovery still fails, include the AkiTTY build, macOS version, Siri language,
and whether the actions appear in Shortcuts when reporting the issue. Terminal
output and command history are not needed for a discovery report.

## Command requests

Request Command always requires approval of the exact command and target in
AkiTTY. Deny is the default. It uses the same command validation, integrated
shell readiness check, input lease, one-shot authorization, bounded approval
lifetime, and event recording as local agent requests. Concurrent requests are
rejected. Cancellation before approval, a closed target, or a stopped request
service prevents approval. Commands run with the shell's existing OS permissions.

Siri and Shortcuts requests do not enable the local request socket. The
**Enable Local Agent Requests** setting continues to apply to socket clients.
The event timeline identifies a system-intent request as `siri_shortcuts`,
without claiming that the caller was necessarily spoken Siri rather than a
Shortcuts automation. Events contain command hashes and lengths, not command
text or terminal output.

After approval, the response reports dispatch, not successful completion.
Review the terminal and use **Reclaim Terminal Control** to return input to
yourself. Reclaim does not stop a running process. Never retry automatically
when a dispatch outcome is uncertain. Ordinary coding-agent operations remain
governed by that agent's permissions; this integration does not intercept them.

## Terminal references and runtime behavior

AkiTTY models live panes as enumerable, searchable `TerminalEntity` values.
New Terminal, Open Folder, New Tab, and Split Pane return entities. Focus
Terminal, Terminal Status, Request Command, New Tab, and Split Pane accept an
entity, allowing Shortcuts workflows to pass exact pane references between
actions. Each pane's AppKit view carries its entity identifier. A transferable
text representation contains its name, reported status, host input ownership,
and shell-reported readiness.
Terminal Status reads a fresh core snapshot instead of repeating fields from
a previously returned entity. Full terminal output, environment variables,
command history, and working-directory fields are not exported or persistently
indexed by this integration. Program reports remain unverified.

All ten actions require local device authentication. List Terminals and
Terminal Status declare the stable `supportedModes = .background` API: each
reads only bounded metadata, never shows a window or approval sheet, and can
answer without bringing AkiTTY forward. The other eight actions use
`.foreground(.immediate)`, bringing AkiTTY forward before they run. A cold
launch for a background request does not activate the app when no window
exists; a default launch, a folder opened before launch, or a foreground action
still does. The native package, Rust build, app plist, installer, and
metadata extractor all target macOS 27.2. There is one build mode for Siri;
experimental tool annotations, app skills, and preview packaging are removed.
No terminal-specific system schema models these operations, so AkiTTY uses
custom entities and actions.

AkiTTY does not include an agent that can independently complete an open-ended
request such as "fix this project." Request Command submits an exact shell
command for approval. This integration exposes the listed App Shortcuts;
arbitrary conversational tool selection and multi-action orchestration are
outside the qualified scope.

## Implementation plan and build verification

The implementation follows these steps:

1. Define specific intents with meaningful titles, descriptions, parameters,
   authentication, and foreground behavior; provide a single App Shortcuts provider.
2. Resolve current pane entities by app-instance and session identifiers, reject
   closed or stale references, and annotate the corresponding AppKit views.
3. Reuse native command approval and event handling for both system intents and
   existing socket clients; preserve cancellation and uncertain-dispatch handling.
4. Extract library metadata, merge it into app metadata, validate the ten default
   shortcuts and entity declarations, and train the phrases before signing.
5. Test pane resolution, startup, visibility, cancellation, denial, and real PTY
   dispatch, then qualify actual Siri recognition on supported devices.

App packaging uses stable Xcode 27.2 with the Swift build engine, which produces
the compiler's `.swiftconstvalues` files. `build-siri-metadata.py` invokes Apple's
metadata extractor for the library and app and the phrase training processor.
The provider lives in the executable target because merging static library
action metadata does not preserve that library's default App Shortcuts.
Packaging fails if required metadata, shortcuts, or intent modes are missing:
`ListTerminalsIntent` and `GetTerminalStatusIntent` must declare the background
encoding, and every other action must stay foreground-immediate.
`Contents/Resources/Metadata.appintents` is created before code signing.
The bundle declares English as its development language. The packaging check
also verifies that phrase training contains actual utterances: without a
development language, Apple's processor can succeed with empty training data.

Automated checks:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
# Confirm this is the stable Xcode 27.2 installation.
xcodebuild -version
bash scripts/verify.sh
bash scripts/build-app.sh debug
```

The full gate covers native intent behavior, real PTY dispatch, installer OS
boundaries, release metadata, and the Web/Rust suites. Packaging checks all ten
actions, default shortcuts, the read-only background allowlist, and nonempty
phrase training. Debug and optimized Swift builds must produce equivalent
intent metadata.

The macOS 27.2 baseline (`905984f`) passed the full gate, app bundle/signature
checks, and both debug and optimized Swift metadata extraction. The native
suite executed 282 tests with zero failures and one benchmark skipped. Web
tests passed, including 22 Chromium/WebKit browser checks; Firefox could not
start locally because of a profile error and remains a CI qualification item.
These results do not establish spoken Siri recognition or system discovery.

Device qualification still needs the following checks on the installed macOS
27.2 bundle; calling `perform()` in a unit test does not establish spoken Siri
recognition or system discovery:

- Confirm that all ten actions appear under AkiTTY in Shortcuts and Spotlight,
  and that List Terminals and Terminal Status answer without activating AkiTTY.
- Quit AkiTTY uncleanly (Force Quit, or turn off "Close windows when quitting an app"
  in Desktop & Dock), then ask List Terminals with AkiTTY closed. It must still
  answer without opening a window; a normal launch afterwards must open one.
- Invoke each listed phrase with Siri, with the app both closed and running.
  New Terminal must create one window, Open Folder must open the chosen folder,
  New Tab must add a tab, Split Pane must add a pane, and Show Quick Terminal
  must keep the existing quick terminal visible on repeated requests.
- Select among similarly named panes, focus a background tab and hidden quick
  terminal, close a selected pane, and restart AkiTTY with an old pane reference.
- Split a tab until it holds eight panes and confirm a ninth reports the limit
  instead of failing silently.
- Invoke Terminal Status after a program report or input-ownership change.
  Verify its spoken response distinguishes unverified reports from host control,
  and that List Terminals remains brief when many panes are open.
- Request a harmless command such as `pwd`; deny it, cancel it, then explicitly
  approve it. Verify the target, lease, and event timeline. Check locked-device
  authentication and timeout behavior.

## Apple references reviewed before implementation

- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [supportedModes](https://developer.apple.com/documentation/appintents/appintent/supportedmodes)
- [Configuring intent runtime behavior](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)
- [AppIntentsPackage](https://developer.apple.com/documentation/appintents/appintentspackage)
- [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [Providing contextual cues](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements)
