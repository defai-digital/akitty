# Reproducible local agent approval demo

Build the app (`bash scripts/build-app.sh debug`) and open it. Choose **Akitty → Enable Local Agent Requests**,
then leave a local integrated bash/zsh pane at an unedited prompt. The service is off again after app restart.

Find the target explicitly:

```sh
build/Akitty.app/Contents/MacOS/akitty-agent list
```

Copy a `pane` value. Run this from another shell or an agent capable of invoking a local CLI:

```sh
python3 scripts/agent-demo.py --cli build/Akitty.app/Contents/MacOS/akitty-agent --pane '<pane-id>' --expect denied
```

Choose **Deny** in AkiTTY. The JSON report should say `dispatch: denied`, `effect: not_observed` and
`reclaim_required: false`. Run again with `--expect approved` and choose **Run Command**. This requests one
generated `printf` command writing a random marker inside a private temporary directory. The report distinguishes:

| Field | Meaning |
| --- | --- |
| `requested` | The demo attempted one companion request. |
| `dispatch: queued` | A valid host receipt accepted the exact input once. |
| `effect: expected_marker_observed` | The demo separately read the expected random bytes from its file. |
| `completion: unverified` | A shell completion or general execution guarantee was not established. |
| `reclaim_required: true` | Input remains leased until an explicit human reclaim or trusted-host release. |

Choose **Edit → Reclaim Terminal Control** afterward. Reclaim changes input ownership; it does not kill a process.
`event_session`, `after_command_id` and `command_sha256` support correlation without turning program reports into proof.
The generated marker is cleaned up at the end. A queued receipt without the expected effect is a failing demo,
not success. Malformed responses, lost transport and uncertain dispatches are never retried automatically.
Marker reads use nonblocking, no-follow opens and verify an owned, single-link regular file before reading.
Symlinks, hard links and FIFOs cannot establish the expected effect or turn the observation into a blocking pipe read.

The companion can target a separate test instance with `--socket`; pass that path to the demo as well.
This is a local observer demonstration, not tamper-resistant execution attestation or interception of the agent's
other commands. The app still requires human approval for each managed request; the paste preference does not
alter command approval.

## Automated reproduction

```sh
python3 scripts/test_agent_demo.py
swift test --package-path macos --filter AgentRequestTests.testDemoScriptUsesTheRealCompanionAndApprovalUI
```

The native regression runs the real Python demo, bundled companion, Unix socket, approval sheet and PTY in
isolated temporary directories. It exercises both denial and approval and checks that input ownership remains
leased after dispatch until explicitly reclaimed. This does not certify any vendor-specific agent adapter.
