#!/usr/bin/env bash

# Find and switch to the next 'done' or 'wait' window

STATUS_DIR="$HOME/.cache/tmux-agent-status"

# Key helper functions
key_session() { echo "${1%__w*}"; }
key_window() { echo "${1##*__w}"; }

has_agent_in_window() {
    local session="$1"
    local window="$2"

    while IFS=: read -r pane_id pane_pid; do
        if pgrep -P "$pane_pid" -f "claude|codex" >/dev/null 2>&1; then
            return 0
        fi
    done < <(tmux list-panes -t "$session:$window" -F "#{pane_id}:#{pane_pid}" 2>/dev/null)

    return 1
}

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

get_agent_status() {
    local key="$1"
    local session
    session=$(key_session "$key")

    local remote_status="$STATUS_DIR/${key}-remote.status"
    if [ -f "$remote_status" ] && is_ssh_session "$session"; then
        cat "$remote_status" 2>/dev/null
        return
    elif [ -f "$remote_status" ] && ! is_ssh_session "$session"; then
        rm -f "$remote_status" 2>/dev/null
    fi

    local status_file="$STATUS_DIR/${key}.status"
    if [ -f "$status_file" ]; then
        cat "$status_file" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Get current session and window
current_session=$(tmux display-message -p "#{session_name}")
current_window=$(tmux display-message -p "#{window_index}")
current_target="${current_session}:${current_window}"

# Collect all done windows with their completion times
done_windows_with_times=()
while IFS=: read -r name window; do
    [ -z "$name" ] && continue
    key="${name}__w${window}"
    target="${name}:${window}"

    agent_status=$(get_agent_status "$key")
    has_agent=false

    if has_agent_in_window "$name" "$window"; then
        has_agent=true
    elif [ -n "$agent_status" ] && is_ssh_session "$name"; then
        has_agent=true
    fi

    if [ "$has_agent" = true ] && { [ "$agent_status" = "done" ] || [ "$agent_status" = "wait" ] || [ "$agent_status" = "ask" ]; } && [ "$target" != "$current_target" ]; then
        status_file=""
        if is_ssh_session "$name"; then
            status_file="$STATUS_DIR/${key}-remote.status"
        else
            status_file="$STATUS_DIR/${key}.status"
        fi

        completion_time=0
        if [ -f "$status_file" ]; then
            completion_time=$(stat -f %m "$status_file" 2>/dev/null || stat -c %Y "$status_file" 2>/dev/null || echo 0)
        fi

        done_windows_with_times+=("$completion_time:$target")
    fi
done < <(tmux list-windows -a -F "#{session_name}:#{window_index}" 2>/dev/null || echo "")

# Sort by completion time (most recent first) and extract targets
IFS=$'\n' sorted_windows=($(printf '%s\n' "${done_windows_with_times[@]}" | sort -t: -k1,1nr | cut -d: -f2-))
done_windows=("${sorted_windows[@]}")

if [ ${#done_windows[@]} -eq 0 ]; then
    tmux display-message "No done/waiting projects found"
    exit 0
fi

# Find current target index in done windows
current_index=-1
for i in "${!done_windows[@]}"; do
    if [ "${done_windows[$i]}" = "$current_target" ]; then
        current_index=$i
        break
    fi
done

# Calculate next index
if [ $current_index -eq -1 ]; then
    next_target="${done_windows[0]}"
else
    next_index=$(( (current_index + 1) % ${#done_windows[@]} ))
    next_target="${done_windows[$next_index]}"
fi

tmux switch-client -t "$next_target"
