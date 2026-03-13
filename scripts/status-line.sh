#!/usr/bin/env bash

# Status line script for tmux status bar
# Shows agent status across all windows

STATUS_DIR="$HOME/.cache/tmux-agent-status"
LAST_STATUS_FILE="$STATUS_DIR/.last-status-summary"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Key helper functions: extract session/window from a key like "myproject__w0"
key_session() { echo "${1%__w*}"; }
key_window() { echo "${1##*__w}"; }

is_ssh_session() {
    local session="$1"
    if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
        return 0
    fi
    case "$session" in
        reachgpu) return 0 ;;
        *) return 1 ;;
    esac
}

# Check for agent processes (Codex) via process polling
find_window_codex_pid() {
    local session="$1"
    local window="$2"

    while IFS=: read -r pane_id pane_pid; do
        local found_pid
        found_pid=$(pgrep -P "$pane_pid" -f "codex" 2>/dev/null | head -1)
        if [ -n "$found_pid" ]; then
            echo "$found_pid"
            return 0
        fi
    done < <(tmux list-panes -t "$session:$window" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)

    return 1
}

get_deepest_codex_pid() {
    local codex_pid="$1"
    local child_codex_pid=""

    while :; do
        child_codex_pid=$(pgrep -P "$codex_pid" -f "codex" 2>/dev/null | head -1)
        [ -z "$child_codex_pid" ] && break
        codex_pid="$child_codex_pid"
    done

    echo "$codex_pid"
}

codex_session_is_working() {
    local codex_pid="$1"
    [ -z "$codex_pid" ] && return 1

    local worker_pid
    worker_pid=$(get_deepest_codex_pid "$codex_pid")
    [ -z "$worker_pid" ] && return 1

    pgrep -P "$worker_pid" >/dev/null 2>&1
}

check_agent_processes() {
    while IFS=: read -r session window; do
        [ -z "$session" ] && continue
        local key="${session}__w${window}"
        local status_file="$STATUS_DIR/${key}.status"
        local codex_pid=""

        codex_pid=$(find_window_codex_pid "$session" "$window" 2>/dev/null)

        if [ -n "$codex_pid" ]; then
            local current_status
            current_status=$(cat "$status_file" 2>/dev/null)
            if [ -z "$current_status" ]; then
                echo "working" > "$status_file"
            elif [ "$current_status" = "done" ] && codex_session_is_working "$codex_pid"; then
                echo "working" > "$status_file"
            fi
        fi
    done < <(tmux list-windows -a -F "#{session_name}:#{window_index}" 2>/dev/null)
}

check_agent_processes

# Count agent sessions by status
count_agent_status() {
    local working=0
    local wait=0
    local ask=0
    local done=0
    local total_agents=0

    while IFS=: read -r session window; do
        [ -z "$session" ] && continue
        local key="${session}__w${window}"

        local remote_status_file="$STATUS_DIR/${key}-remote.status"
        local status_file="$STATUS_DIR/${key}.status"

        if [ -f "$remote_status_file" ] && is_ssh_session "$session"; then
            local status=$(cat "$remote_status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_agents++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((wait++)) ;;
                esac
            fi
        elif [ -f "$remote_status_file" ] && ! is_ssh_session "$session"; then
            rm -f "$remote_status_file" 2>/dev/null
            if [ -f "$status_file" ]; then
                local status=$(cat "$status_file" 2>/dev/null)
                if [ -n "$status" ]; then
                    ((total_agents++))
                    case "$status" in
                        "working") ((working++)) ;;
                        "done") ((done++)) ;;
                        "wait") ((wait++)) ;;
                        "ask") ((ask++)) ;;
                    esac
                fi
            fi
        elif [ -f "$status_file" ]; then
            local status=$(cat "$status_file" 2>/dev/null)
            if [ -n "$status" ]; then
                ((total_agents++))
                case "$status" in
                    "working") ((working++)) ;;
                    "done") ((done++)) ;;
                    "wait") ((wait++)) ;;
                esac
            fi
        fi
    done < <(tmux list-windows -a -F "#{session_name}:#{window_index}" 2>/dev/null)

    echo "$working:$wait:$ask:$done:$total_agents"
}

# Play notification sound
play_notification() {
    "$SCRIPT_DIR/play-sound.sh" &
}

# Get current status
IFS=':' read -r working wait ask done total_agents <<< "$(count_agent_status)"

# Load previous status
prev_done=""
if [ -f "$LAST_STATUS_FILE" ]; then
    prev_status=$(cat "$LAST_STATUS_FILE" 2>/dev/null || echo "")
    if [[ "$prev_status" == *:* ]]; then
        prev_done=$(echo "$prev_status" | awk -F: '{print $(NF)}')
    fi
fi

# Save current status counts
echo "$working:$wait:$ask:$done" > "$LAST_STATUS_FILE"

# Check if any agent just finished (done count increased)
if [ -n "$prev_done" ] && [ "$done" -gt "$prev_done" ]; then
    play_notification
fi

format_working_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=yellow,bold]⚡ agent working#[default]"
    else
        echo "#[fg=yellow,bold]⚡ $count working#[default]"
    fi
}

format_wait_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=magenta,bold]🔔 1 waiting#[default]"
    else
        echo "#[fg=magenta,bold]🔔 $count waiting#[default]"
    fi
}

format_ask_segment() {
    local count="$1"
    if [ "$count" -eq 1 ]; then
        echo "#[fg=cyan,bold]💬 1 asking#[default]"
    else
        echo "#[fg=cyan,bold]💬 $count asking#[default]"
    fi
}

format_done_segment() {
    local count="$1"
    echo "#[fg=green]✓ $count done#[default]"
}

# Generate status line output
if [ "$total_agents" -eq 0 ]; then
    echo ""
elif [ "$working" -eq 0 ] && [ "$wait" -eq 0 ] && [ "$ask" -eq 0 ] && [ "$done" -gt 0 ]; then
    echo "#[fg=green,bold]✓ All agents ready#[default]"
else
    segments=()
    [ "$working" -gt 0 ] && segments+=("$(format_working_segment "$working")")
    [ "$wait" -gt 0 ] && segments+=("$(format_wait_segment "$wait")")
    [ "$ask" -gt 0 ] && segments+=("$(format_ask_segment "$ask")")
    [ "$done" -gt 0 ] && segments+=("$(format_done_segment "$done")")
    printf '%s\n' "${segments[*]}"
fi
