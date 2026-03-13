#!/usr/bin/env bash

# Smart monitoring daemon that runs when SSH sessions exist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
DAEMON_PID_FILE="$STATUS_DIR/smart-monitor.pid"

# Function to check if any SSH sessions exist
has_ssh_sessions() {
    local found_ssh=false
    while read -r session; do
        if tmux list-panes -t "$session" -F "#{pane_current_command}" 2>/dev/null | grep -q "^ssh$"; then
            found_ssh=true
            break
        fi
    done < <(tmux list-sessions -F "#{session_name}" 2>/dev/null)

    if [ "$found_ssh" = true ]; then
        return 0
    fi

    tmux list-sessions -F "#{session_name}" 2>/dev/null | grep -q "^reachgpu$"
}

# Function to check if daemon should keep running
should_run() {
    tmux list-sessions >/dev/null 2>&1 && has_ssh_sessions
}

# Function to update SSH session status
update_ssh_status() {
    _update_ssh_session() {
        local session="$1"
        local ssh_host="$2"

        tmux has-session -t "$session" 2>/dev/null || return

        local temp_dir
        temp_dir=$(mktemp -d "$STATUS_DIR/.ssh-sync-XXXXXX")

        if ssh -o ConnectTimeout=2 -o BatchMode=yes -o StrictHostKeyChecking=no -o LogLevel=QUIET \
            "$ssh_host" "for f in ~/.cache/tmux-agent-status/${session}__w*.status; do [ -f \"\$f\" ] && echo \"\$(basename \"\$f\"):\$(cat \"\$f\")\"; done" \
            > "$temp_dir/output" 2>/dev/null; then

            while IFS=: read -r fname remote_status; do
                [ -z "$fname" ] && continue
                local key="${fname%.status}"
                echo "$remote_status" > "$STATUS_DIR/${key}-remote.status"
            done < "$temp_dir/output"
        fi

        rm -rf "$temp_dir"
    }

    _update_ssh_session "reachgpu" "reachgpu"
    _update_ssh_session "tig" "nga100"
    _update_ssh_session "l4-workstation" "l4-workstation"

    # ADD_SSH_SESSIONS_HERE
}

# Function to start monitoring
start_monitor() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local old_pid=$(cat "$DAEMON_PID_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            return 0
        else
            rm -f "$DAEMON_PID_FILE"
        fi
    fi

    (
        while should_run; do
            update_ssh_status
            sleep 1
        done
        rm -f "$DAEMON_PID_FILE"
    ) &

    echo $! > "$DAEMON_PID_FILE"
}

# Function to stop monitoring
stop_monitor() {
    if [ -f "$DAEMON_PID_FILE" ]; then
        local pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid"
        fi
        rm -f "$DAEMON_PID_FILE"
    fi
}

# Function to check status
check_status() {
    if [ -f "$DAEMON_PID_FILE" ] && kill -0 "$(cat "$DAEMON_PID_FILE" 2>/dev/null)" 2>/dev/null; then
        echo "Smart monitor running (PID: $(cat "$DAEMON_PID_FILE"))"
        return 0
    else
        echo "Smart monitor not running"
        return 1
    fi
}

# Main command handling
case "${1:-start}" in
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    status)
        check_status
        ;;
    update)
        update_ssh_status
        ;;
    *)
        echo "Usage: $0 {start|stop|status|update}"
        exit 1
        ;;
esac
