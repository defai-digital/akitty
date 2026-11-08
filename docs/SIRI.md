# Siri, Shortcuts, and Siri AI

AkiTTY includes seven App Intents and matching App Shortcuts. The shortcuts ship
with the app; users do not need to build their own workflow first. The bundled
trigger phrases are in English. Enable Siri
in macOS and use the installed app. System language, region, device support,
and Siri settings affect discovery and speech recognition.

| Action | Example Siri phrase | Behavior |
| --- | --- | --- |
| New Terminal | “Open a new terminal in AkiTTY” | Creates a window with the configured shell and directory; returns its pane reference. |
| Show Quick Terminal | “Show the quick terminal in AkiTTY” | Shows the persistent quick terminal; repeating the request keeps it visible. |
| Agent Overview | “Show agents in AkiTTY” | Shows reported activity and input ownership across windows and panes. |
| List Terminals | “List terminals in AkiTTY” | Returns current panes and speaks a brief list of names, including the total count. |
| Terminal Status | “Get terminal status in AkiTTY” | Prompts for a pane and reads fresh reported activity, input ownership, and shell readiness. |
| Focus Terminal | “Focus a terminal in AkiTTY” | Prompts for a pane and brings its window and tab forward. |
| Request Command | “Request a command in AkiTTY” | Prompts for a pane and exact command, then opens the native approval sheet. |

For actions with required parameters, Siri or Shortcuts asks for the missing
values. Complex shell quoting and punctuation are best entered in Shortcuts
or reviewed carefully in the approval sheet. The App Shortcuts phrases include
the app name. A terminal reference is valid only while that pane remains open
in the same app instance; saved shortcuts must query or select current panes.

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

## macOS 27 Siri AI

Apple's November 3, 2026 announcement expands third-party integration in the
**macOS 27.3 Siri AI Developer Preview**. It adds custom tool intents,
conversational references to onscreen content, custom content discovery, and
app skills for guiding multi-action tasks. Custom tools require an explicit
`@AppIntent(.tool)` annotation. An ordinary App Shortcut alone does not opt a
custom action into that tool catalog.

AkiTTY models live panes as enumerable, searchable `TerminalEntity` values.
New Terminal returns an entity, List Terminals returns entities, and Focus
Terminal and Request Command accept an entity, so workflows can pass exact pane
references between actions. On macOS 15.4+, each pane's AppKit view also carries
its entity identifier for onscreen context. A transferable text representation
contains its name, reported status, host input ownership, and shell-reported
readiness. Terminal Status reads a fresh core snapshot and resolves the current
pane instead of repeating fields from a previously returned entity. Full terminal output, environment
variables, command history, and working-directory fields are not exported or
persistently indexed by this integration. Program reports remain unverified.

All seven actions require local device authentication and run in the foreground.
macOS 26+ uses `supportedModes`; earlier systems use `openAppWhenRun`. No
terminal-specific system schema currently models these operations, so AkiTTY
uses custom entities and actions rather than assigning an unrelated schema.

### Preview builds

The regular build supports macOS 14+. A separate developer-preview build opts
the same seven actions into Siri AI as custom tools:

```sh
AKITTY_SIRI_AI_PREVIEW=1 bash scripts/build-app.sh debug
```

This build requires a macOS 27.3+ SDK and targets macOS 27.3+. The build script
rejects an older SDK before rebuilding the app. It does not replace the stable
macOS 14 deployment target for regular builds. Use an appropriate development
signature and provisioning profile, and a device with Siri AI enabled and a
supported language. The script's default ad-hoc signature is for local bundle
checks and is not proof that Siri AI will accept the preview build.

Apple limits the developer preview to development-signed device builds and
internal TestFlight testers; public App Store builds and external TestFlight
testing are not supported by the preview. Arbitrary natural-language custom
tool selection, multi-action orchestration, and app skills must therefore be
qualified separately from the regular App Shortcuts integration.

Two app skill sources are prepared in `macos/Siri/Skills.skillsbundle`: one for
inspecting terminal activity and one for requesting an exact command. Their
guidance covers pane disambiguation, fresh status, native approval, and uncertain
dispatch. They guide Siri; enforcement remains in the native command host.

These sources are not compiled or bundled by `build-app.sh`. The source checker
validates Apple's documented directory structure, metadata, and length limits;
it does not replace Apple's skills compiler. Compiling them into the main app
through the preview Xcode build pipeline and verifying their selection remain
outstanding. The Siri Integration Advisor and SiriEvaluations also need that
preview development environment. AkiTTY does not include an agent that can independently complete “fix this project.”
Request Command submits a shell command for approval, not an open-ended task to
an external coding agent.

### Upgrade the development environment

Xcode 27.3 beta includes the macOS 27.3 SDK and can run on this project's current
macOS 27.2 host. Download it from Apple's authenticated developer downloads and
install it alongside the stable Xcode app. Select it for a build with
`DEVELOPER_DIR` rather than replacing the machine-wide toolchain selection:

For an `.aea` package, wait for the browser download to finish, then extract it
using Apple's bundled tool:

```sh
archiveutil extractXcodeAEA /path/to/Xcode_27.3_beta.aea
```

Keep the extracted app alongside the existing Xcode installation, for example
at `/Applications/Xcode-27.3-beta.app`, and complete Xcode's first-launch setup.
Use that installation for a preview build:

```sh
DEVELOPER_DIR=/Applications/Xcode-27.3-beta.app/Contents/Developer \
    AKITTY_SIRI_AI_PREVIEW=1 bash scripts/build-app.sh debug
```

Installing that SDK permits preview compilation on macOS 27.2; running the
27.3-targeted app and qualifying Siri AI additionally require a macOS 27.3
device and the development signing described above. Confirm the installed
Xcode version and SDK with `xcodebuild -version` and
`xcrun --sdk macosx --show-sdk-version` under that `DEVELOPER_DIR`.

## Implementation plan and build verification

The implementation follows these steps:

1. Define specific intents with meaningful titles, descriptions, parameters,
   authentication, and foreground behavior; provide a single App Shortcuts provider.
2. Resolve current pane entities by app-instance and session identifiers, reject
   closed or stale references, and annotate the corresponding AppKit views.
3. Reuse native command approval and event handling for both system intents and
   existing socket clients; preserve cancellation and uncertain-dispatch handling.
4. Extract library metadata, merge it into app metadata, validate the seven default
   shortcuts and entity declarations, and train the phrases before signing.
5. Test pane resolution, startup, visibility, cancellation, denial, and real PTY
   dispatch, then qualify actual Siri recognition on supported devices.

App packaging requires Xcode 27.2+ with the Swift build engine, which produces
the compiler's `.swiftconstvalues` files. `build-siri-metadata.py` invokes Apple's
metadata extractor for the library and app and the phrase training processor.
The provider lives in the executable target because merging static library
action metadata does not preserve that library's default App Shortcuts.
Packaging fails if required metadata or shortcuts are missing; the final
`Contents/Resources/Metadata.appintents` is created before code signing.
The bundle declares English as its development language. The packaging check
also verifies that phrase training contains actual utterances: without a
development language, Apple's processor can succeed with empty training data.

Automated checks:

```sh
swift test --package-path macos
python3 scripts/test_siri_metadata.py
python3 scripts/test_siri_skills.py
python3 scripts/check-siri-skills.py
bash scripts/build-app.sh debug
```

Device qualification still needs the following checks on the installed bundle:

- Confirm that all seven actions appear under AkiTTY in Shortcuts and Spotlight.
- Invoke each listed phrase with Siri, with the app both closed and running.
  New Terminal must create one window, and Show Quick Terminal must keep the
  existing quick terminal visible on repeated requests.
- Select among similarly named panes, focus a background tab and hidden quick
  terminal, close a selected pane, and restart AkiTTY with an old pane reference.
- Invoke Terminal Status after a program report or input-ownership change.
  Verify its spoken response distinguishes unverified reports from host control,
  and that List Terminals remains brief when many panes are open.
- Request a harmless command such as `pwd`; deny it, cancel it, then explicitly
  approve it. Verify the target, lease, and event timeline. Check locked-device
  authentication and timeout behavior.
- For a development-signed 27.3 preview build, vary natural-language phrasing
  and refer to the onscreen pane. Verify actual tool selection and pane
  disambiguation with Siri Integration Advisor and SiriEvaluations. This is not
  established by calling `perform()` in a unit test.

## Apple references reviewed before implementation

- [App Shortcuts](https://developer.apple.com/documentation/appintents/app-shortcuts)
- [Configuring intent runtime behavior](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents)
- [AppIntentsPackage](https://developer.apple.com/documentation/appintents/appintentspackage)
- [App schema domains](https://developer.apple.com/documentation/appintents/app-schema-domains)
- [Providing contextual cues](https://developer.apple.com/documentation/appintents/providing-contextual-cues-to-apple-intelligence-and-siri)
- [Siri AI developer announcement](https://developer.apple.com/news/?id=gdk2umrf)
- [Siri AI Developer Preview](https://developer.apple.com/documentation/appintents/siri-ai-developer-preview)
- [Bringing custom actions and content to Siri](https://developer.apple.com/documentation/appintents/bringing-custom-actions-and-content-to-siri)
- [Orchestrating complex actions with app skills](https://developer.apple.com/documentation/appintents/orchestrating-complex-actions-with-app-skills)
- [Xcode SDK and system requirements](https://developer.apple.com/xcode/system-requirements)
