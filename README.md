# tmux-agent-status

AI agent session manager for tmux. Monitor and orchestrate multiple AI coding assistants (Claude Code, OpenAI Codex CLI, and custom agents) from your tmux status bar.

Real-time status tracking, session switching, and notification sounds for multi-agent terminal workflows.

![tmux-agent-status screenshot](claude-working-done.png)

## Supported Agents

| Agent | Detection | Status |
|-------|-----------|--------|
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (Anthropic) | Hook-based (5 events) | Stable |
| [Codex CLI](https://github.com/openai/codex) (OpenAI / ChatGPT) | Process polling + notify | Experimental |
| Custom (Aider, Cline, Copilot CLI, etc.) | Status files or process polling | Stable |

All agents can run **simultaneously** across tmux sessions and windows, each tracked independently at the **window level**.

## Install

With [TPM](https://github.com/tmux-plugins/tpm):
```bash
set -g @plugin 'samleeney/tmux-agent-status'
```

Then `prefix + I` to install. Previously `tmux-claude-status`; the old name redirects automatically.

## Claude Code Setup

Add hooks to `~/.claude/settings.json`:
```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh UserPromptSubmit" }] }
    ],
    "PreToolUse": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh PreToolUse" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Stop" }] }
    ],
    "Notification": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh Notification" }] }
    ],
    "PermissionRequest": [
      { "hooks": [{ "type": "command", "command": "~/.config/tmux/plugins/tmux-agent-status/hooks/better-hook.sh PermissionRequest" }] }
    ]
  }
}
```

Precise agent status via [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks). The AI reports its own state transitions. **Note:** After modifying hooks, you must restart Claude Code sessions for changes to take effect.

## OpenAI Codex CLI Setup (Experimental)

Codex CLI (OpenAI's terminal AI agent) lacks full lifecycle hooks ([tracking issue](https://github.com/openai/codex/issues/2109), PRs [#2904](https://github.com/openai/codex/pull/2904), [#9796](https://github.com/openai/codex/pull/9796), [#11067](https://github.com/openai/codex/pull/11067)). This plugin uses a hybrid approach:

- **"Working"**: Process polling (`pgrep`) checks every 1s for a running `codex` process
- **"Done"**: Codex `notify` fires on agent turn completion

Add to `~/.codex/config.toml`:
```toml
notify = ["~/.config/tmux/plugins/tmux-agent-status/hooks/codex-notify.sh"]
```

When Codex ships proper event hooks, the plugin will upgrade to hook-based tracking.

## Custom Agent Integration

Integrate any AI coding tool (Aider, Continue, Cursor, Cline, GitHub Copilot CLI, Goose, Amazon Q, Windsurf, or your own agent):

1. **Status files**: Write `working`, `done`, `wait`, or `ask` to `~/.cache/tmux-agent-status/<session>__w<window_index>.status`
2. **Process polling**: Add your process name to `check_agent_processes()` in `scripts/status-line.sh`

## Agent Statuses

| Status | Icon | Color | Description |
|--------|------|-------|-------------|
| `working` | ⚡ | Yellow | Agent is actively working |
| `wait` | 🔔 | Magenta | Agent is waiting for permission approval (tool use confirmation) |
| `ask` | 💬 | Cyan | Agent is asking a question (e.g., plan mode, `AskUserQuestion`) |
| `done` | ✓ | Green | Agent has finished and is ready for input |

Status bar examples:
- `⚡ agent working` — one agent working
- `⚡ 2 working 🔔 1 waiting 💬 1 asking ✓ 1 done` — mixed states
- `✓ All agents ready` — all agents idle

## Window-Level Granularity

Status is tracked per **window**, not per session. Each tmux window with an AI agent is tracked independently using the file naming convention:

```
~/.cache/tmux-agent-status/<session>__w<window_index>.status
```

For example, `myproject__w0.status` and `myproject__w2.status` can show different statuses simultaneously. This allows running multiple agents in different windows of the same session.

## Usage

| Key | Action |
|-----|--------|
| `prefix + a` | Window switcher: session-grouped view with agent status |
| `prefix + N` | Jump to next done/waiting/asking window |

### Switcher Controls

The `prefix + a` switcher provides a session-grouped view with live pane preview:

| Key | Action |
|-----|--------|
| `Ctrl-J` / `Ctrl-K` | Navigate up / down |
| `Enter` | Switch to selected window |
| `Ctrl-R` | Reset view |
| Type to filter | Search by session/window name |

All sessions are fully expanded. The preview panel preserves terminal colors.

### Keybindings

```tmux
set -g @agent-status-key "a"
set -g @agent-next-done-key "N"
```

Old `@claude-*` options still work as fallbacks.

## Notification Sounds

Plays when an AI agent finishes or requests permission. Done and wait states have separate sound configurations:

```tmux
# Sound when agent finishes (done)
set -g @agent-notification-sound "chime"

# Sound when agent needs permission approval (wait)
set -g @agent-wait-sound "alert"
```

**Done sound** options: `chime` (default), `bell`, `fanfare`, `frog`, `speech` ("Agent ready" TTS), `none`.

**Wait sound** options: `alert` (default, Basso on Mac), `bell`, `chime`, `fanfare`, `frog`, `speech`, `none`.

## Multi-Agent Deploy

Launch parallel AI coding sessions with isolated git worktrees:

```bash
bash ~/.config/tmux/plugins/tmux-agent-status/scripts/deploy-sessions.sh manifest.json
```

Each session gets a `deploy/<name>` branch. The agent orchestrator tracks all spawned sessions automatically.

## SSH Remote Sessions

Monitor AI agents on remote machines (GPU servers, cloud VMs, dev boxes):

```bash
./setup-server.sh <session-name> <ssh-host>
```

Works with GCP, AWS, Azure, Lambda Labs, or any SSH host.

## How It Works

```
┌─────────────┐     hooks      ┌──────────────────────┐
│ Claude Code  ├──────────────►│                      │
└─────────────┘                │  ~/.cache/            │     ┌──────────────┐
                               │  tmux-agent-          ├────►│ tmux status  │
┌─────────────┐  pgrep/notify  │  status/              │     │ bar (1s poll)│
│ Codex CLI   ├──────────────►│  <sess>__w<win>.status │     └──────────────┘
└─────────────┘                │                      │
                               │  "working"           │     ┌──────────────┐
┌─────────────┐  status files  │  "wait" / "ask"      ├────►│ prefix + a   │
│ Custom agent├──────────────►│  "done"               │     │ switcher     │
└─────────────┘                └──────────────────────┘     └──────────────┘
```

- **Claude Code**: Hook-based (5 events). AI agent reports state transitions directly
- **Codex CLI**: Hybrid. Process polling for "working", `notify` for "done"
- **Session manager**: Groups windows by session with live color-preserving preview

## License

MIT
