#!/usr/bin/env bash

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One-time cache directory migration
OLD_DIR="$HOME/.cache/tmux-claude-status"
NEW_DIR="$HOME/.cache/tmux-agent-status"
if [ -d "$OLD_DIR" ] && [ ! -d "$NEW_DIR" ]; then
    mv "$OLD_DIR" "$NEW_DIR"
fi

# Migrate session-level status files to window-level (__w0) format
if [ -d "$NEW_DIR" ]; then
    for f in "$NEW_DIR"/*.status; do
        [ ! -f "$f" ] && continue
        base=$(basename "$f" .status)
        [[ "$base" == *__w* ]] && continue
        [[ "$base" == *-remote ]] && continue
        mv "$f" "$NEW_DIR/${base}__w0.status"
    done
    for f in "$NEW_DIR"/*-remote.status; do
        [ ! -f "$f" ] && continue
        base=$(basename "$f" -remote.status)
        [[ "$base" == *__w* ]] && continue
        mv "$f" "$NEW_DIR/${base}__w0-remote.status"
    done
    # Clean up legacy wait directory
    rm -rf "$NEW_DIR/wait" 2>/dev/null
fi

# Default key bindings
default_switcher_key="a"
default_next_done_key="N"

# Get user configuration or use defaults (check new @agent-* first, fall back to @claude-*)
switcher_key=$(tmux show-option -gqv "@agent-status-key")
[ -z "$switcher_key" ] && switcher_key=$(tmux show-option -gqv "@claude-status-key")
next_done_key=$(tmux show-option -gqv "@agent-next-done-key")
[ -z "$next_done_key" ] && next_done_key=$(tmux show-option -gqv "@claude-next-done-key")

[ -z "$switcher_key" ] && switcher_key="$default_switcher_key"
[ -z "$next_done_key" ] && next_done_key="$default_next_done_key"

# Set up custom session switcher with agent status (hook-based)
tmux bind-key "$switcher_key" display-popup -E -w 80% -h 70% "$CURRENT_DIR/scripts/hook-based-switcher.sh"

# Set up keybinding to switch to next done project
tmux bind-key "$next_done_key" run-shell "$CURRENT_DIR/scripts/next-done-project.sh"

# Detect iTerm2 Control Mode (tmux -CC) and skip status polling / daemons
control_mode=$(tmux display-message -p '#{client_control_mode}' 2>/dev/null)
if [ "$control_mode" = "1" ]; then
    exit 0
fi

# Set up tmux status line integration
tmux set-option -g status-interval 1

# Check if our status is already in the status-right
current_status_right=$(tmux show-option -gqv status-right)
if ! echo "$current_status_right" | grep -q "status-line.sh"; then
    tmux set-option -ag status-right " #($CURRENT_DIR/scripts/status-line.sh)"
fi

# Set up daemon monitor to ensure smart-monitor is always running
tmux set-hook -g session-created "run-shell '$CURRENT_DIR/scripts/daemon-monitor.sh'"

if tmux list-sessions >/dev/null 2>&1; then
    "$CURRENT_DIR/scripts/daemon-monitor.sh" >/dev/null 2>&1
fi
