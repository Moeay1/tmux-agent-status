#!/usr/bin/env bash

# Hook-based window switcher that reads status from files
# Grouped by session with h/l to collapse/expand

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS_DIR="$HOME/.cache/tmux-agent-status"
STATE_FILE="$STATUS_DIR/.switcher-expanded"

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

get_ssh_host() {
    local session="$1"
    if is_ssh_session "$session"; then
        echo "$session"
    fi
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

is_session_expanded() {
    local session="$1"
    [ -f "$STATE_FILE" ] && grep -qxF "$session" "$STATE_FILE" 2>/dev/null
}

# Truncate and pad string to exact display width (handles CJK chars)
truncate_pad() {
    local str="$1"
    local max="${2:-16}"
    python3 -c "
import unicodedata,sys
s=sys.argv[1]; m=int(sys.argv[2]); w=0; r=''
for c in s:
    cw=2 if unicodedata.east_asian_width(c) in ('W','F') else 1
    if w+cw>m:
        r+='…'; w+=1; break
    r+=c; w+=cw
print(r+' '*(m-w))
" "$str" "$max" 2>/dev/null || printf "%-${max}s" "${str:0:$max}"
}

format_status_badge() {
    local status="$1"
    case "$status" in
        working) printf '\033[1;33m⚡working\033[0m' ;;
        wait)    printf '\033[1;35m🔔 wait\033[0m' ;;
        ask)     printf '\033[1;36m💬 asking\033[0m' ;;
        done)    printf '\033[1;32m✓ done\033[0m' ;;
        *)       printf '\033[1;90mno agent\033[0m' ;;
    esac
}

# Build the grouped list using temp files (bash 3.2 compatible)
get_grouped_list() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf '$tmp_dir'" RETURN

    # Format: session\twindow\twin_name\tpanes\tattached\teffective_status
    while IFS=$'\t' read -r name window win_name panes attached; do
        [ -z "$name" ] && continue
        local key="${name}__w${window}"

        local agent_status=$(get_agent_status "$key")
        local has_agent=false

        if has_agent_in_window "$name" "$window"; then
            has_agent=true
        elif [ -n "$agent_status" ] && is_ssh_session "$name"; then
            has_agent=true
        else
            if [ -n "$agent_status" ] && ! is_ssh_session "$name"; then
                rm -f "$STATUS_DIR/${key}.status" 2>/dev/null
                agent_status=""
            fi
        fi

        local effective_status=""
        if [ "$has_agent" = true ]; then
            [ -z "$agent_status" ] && agent_status="done"
            effective_status="$agent_status"
        fi

        win_name_safe="${win_name//|/-}"
        echo "${name}|${window}|${win_name_safe}|${panes}|${attached}|${effective_status}" >> "$tmp_dir/windows"
    done < <(tmux list-windows -a -F "#{session_name}	#{window_index}	#{window_name}	#{window_panes}	#{?session_attached,(attached),}" 2>/dev/null || echo "")

    [ ! -f "$tmp_dir/windows" ] && return

    # Sort sessions: those with agents first, then those without
    awk -F'|' '!seen[$1]++ {print $1}' "$tmp_dir/windows" > "$tmp_dir/all_sessions"
    > "$tmp_dir/has_agent"
    > "$tmp_dir/no_agent"
    while IFS= read -r _sess; do
        if awk -F'|' "\$1==\"$_sess\" && \$6!=\"\"" "$tmp_dir/windows" | grep -q .; then
            echo "$_sess" >> "$tmp_dir/has_agent"
        else
            echo "$_sess" >> "$tmp_dir/no_agent"
        fi
    done < "$tmp_dir/all_sessions"
    cat "$tmp_dir/has_agent" "$tmp_dir/no_agent" > "$tmp_dir/sessions"

    while IFS= read -r session; do
        [ -z "$session" ] && continue

        grep "^${session}|" "$tmp_dir/windows" > "$tmp_dir/cur_windows"
        local win_count=$(wc -l < "$tmp_dir/cur_windows" | tr -d ' ')

        # Count statuses
        local s_working=0 s_wait=0 s_ask=0 s_done=0
        while IFS='|' read -r _ _ _ _ _ _st; do
            case "$_st" in
                working) s_working=$((s_working + 1)) ;;
                wait)    s_wait=$((s_wait + 1)) ;;
                ask)     s_ask=$((s_ask + 1)) ;;
                done)    s_done=$((s_done + 1)) ;;
            esac
        done < "$tmp_dir/cur_windows"

        local first_attached=$(head -1 "$tmp_dir/cur_windows" | cut -d'|' -f5)
        local ssh_label=""
        is_ssh_session "$session" && ssh_label=" [ssh]"

        if [ "$win_count" -eq 1 ]; then
            IFS='|' read -r _s _w _wn _p _att _st < "$tmp_dir/cur_windows"
            local pane_label="${_p} pane"
            [ "$_p" -gt 1 ] && pane_label="${_p} panes"
            local badge=$(format_status_badge "$_st")
            local trunc_wn=$(truncate_pad "$_wn" 18)
            printf "  \033[1m%-18s\033[0m  %s  %-10s%s  %b\n" "${session}:${_w}" "$trunc_wn" "$_att" "$ssh_label" "$badge"
        else
            local expanded=false
            is_session_expanded "$session" && expanded=true

            local summary=""
            [ "$s_working" -gt 0 ] && summary="${summary}\033[1;33m⚡${s_working}\033[0m "
            [ "$s_wait" -gt 0 ] && summary="${summary}\033[1;35m🔔${s_wait}\033[0m "
            [ "$s_ask" -gt 0 ] && summary="${summary}\033[1;36m💬${s_ask}\033[0m "
            [ "$s_done" -gt 0 ] && summary="${summary}\033[1;32m✓${s_done}\033[0m "

            local win_label="${win_count} wins"

            local indicator="▶"
            $expanded && indicator="▼"

            printf "\033[1m%s %s\033[0m  (%s)  %b %s%s\n" "$indicator" "$session" "$win_label" "$summary" "$first_attached" "$ssh_label"

            if $expanded; then
                while IFS='|' read -r _s _w _wn _p _att _st; do
                    local pane_label="${_p} pane"
                    [ "$_p" -gt 1 ] && pane_label="${_p} panes"
                    local badge=$(format_status_badge "$_st")
                    local trunc_wn=$(truncate_pad "$_wn" 18)
                    printf "    \033[0;37m%-18s\033[0m  %s  %b\n" "${session}:${_w}" "$trunc_wn" "$badge"
                done < "$tmp_dir/cur_windows"
            fi
        fi
    done < "$tmp_dir/sessions"

    echo ""
    printf "\033[1;36m h/l: collapse/expand | H/L: all | Ctrl-R: reset | Enter: select \033[0m\n"
}

# Handle --list flag (used by fzf reload)
if [ "$1" = "--list" ]; then
    get_grouped_list
    exit 0
fi

# Handle --no-fzf flag for daemon refresh
if [ "$1" = "--no-fzf" ]; then
    get_grouped_list
    exit 0
fi

# Handle --expand <session>
if [ "$1" = "--expand" ] && [ -n "$2" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    if ! grep -qxF "$2" "$STATE_FILE" 2>/dev/null; then
        echo "$2" >> "$STATE_FILE"
    fi
    exit 0
fi

# Handle --collapse <session>
if [ "$1" = "--collapse" ] && [ -n "$2" ]; then
    if [ -f "$STATE_FILE" ]; then
        grep -vxF "$2" "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null
        mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi
    exit 0
fi

# Handle --expand-all
if [ "$1" = "--expand-all" ]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    tmux list-windows -a -F "#{session_name}" 2>/dev/null | sort | uniq -d > "$STATE_FILE"
    exit 0
fi

# Handle --collapse-all
if [ "$1" = "--collapse-all" ]; then
    > "$STATE_FILE"
    exit 0
fi

# Function to perform full reset
perform_full_reset() {
    pkill -f "daemon-monitor.sh" 2>/dev/null
    pkill -f "smart-monitor.sh" 2>/dev/null

    find "$STATUS_DIR" -type f -name "*.pid" -delete 2>/dev/null
    rm -f "$STATUS_DIR"/.*.status.tmp 2>/dev/null

    for status_file in "$STATUS_DIR"/*.status; do
        [ ! -f "$status_file" ] && continue
        local key=$(basename "$status_file" .status)
        [[ "$key" == *"-remote" ]] && continue

        local sess=$(key_session "$key")
        local win=$(key_window "$key")
        if ! has_agent_in_window "$sess" "$win"; then
            rm -f "$status_file"
        fi
    done

    "$SCRIPT_DIR/../smart-monitor.sh" stop >/dev/null 2>&1
    "$SCRIPT_DIR/../smart-monitor.sh" start >/dev/null 2>&1
    "$SCRIPT_DIR/daemon-monitor.sh" >/dev/null 2>&1 &
}

# Handle --reset flag for full reset
if [ "$1" = "--reset" ]; then
    perform_full_reset
    get_grouped_list
    exit 0
fi

# Initialize state: start expanded
tmux list-windows -a -F "#{session_name}" 2>/dev/null | sort | uniq -d > "$STATE_FILE"

# Main: launch fzf
ME="$0"
selected=$(get_grouped_list | fzf \
    --ansi \
    --no-sort \
    --header="h/l: collapse/expand | H/L: all | Enter: select | Ctrl-R: reset" \
    --preview '
        line={}
        target=""
        clean=$(echo "$line" | sed "s/$(printf "\033")\[[0-9;]*m//g")
        # Extract session:window pattern from the line
        target=$(echo "$clean" | grep -oE "[a-zA-Z0-9_-]+:[0-9]+" | head -1)
        if [ -z "$target" ]; then
            # Session header line (▶/▼ session): use first window
            first=$(echo "$clean" | awk "{print \$1}")
            if [ "$first" = "▶" ] || [ "$first" = "▼" ]; then
                sess=$(echo "$clean" | awk "{print \$2}")
                target=$(tmux list-windows -t "$sess" -F "#{session_name}:#{window_index}" 2>/dev/null | head -1)
            fi
        fi
        if [ -n "$target" ]; then
            tmux capture-pane -e -p -t "$target" 2>/dev/null || echo "No preview available"
        else
            echo ""
        fi
    ' \
    --preview-window=right:50% \
    --prompt="Window> " \
    --bind="j:down,k:up,ctrl-j:preview-down,ctrl-k:preview-up" \
    --bind="ctrl-r:reload(bash '$ME' --reset)" \
    --bind='l:execute-silent(clean=$(echo {} | sed "s/$(printf "\033")\[[0-9;]*m//g"); first=$(echo "$clean" | awk "{print \$1}"); if [ "$first" = "▶" ]; then sess=$(echo "$clean" | awk "{print \$2}"); bash '"'$ME'"' --expand "$sess"; fi)+reload(bash '"'$ME'"' --list)' \
    --bind='h:execute-silent(clean=$(echo {} | sed "s/$(printf "\033")\[[0-9;]*m//g"); first=$(echo "$clean" | awk "{print \$1}"); if [ "$first" = "▼" ]; then sess=$(echo "$clean" | awk "{print \$2}"); bash '"'$ME'"' --collapse "$sess"; else t=$(echo "$clean" | awk "{print \$1}"); s=${t%%:*}; bash '"'$ME'"' --collapse "$s"; fi)+reload(bash '"'$ME'"' --list)' \
    --bind='L:execute-silent(bash '"'$ME'"' --expand-all)+reload(bash '"'$ME'"' --list)' \
    --bind='H:execute-silent(bash '"'$ME'"' --collapse-all)+reload(bash '"'$ME'"' --list)' \
    --layout=reverse \
    --info=inline)

# Clean up state file
rm -f "$STATE_FILE"

# Switch to selected target
if [ -n "$selected" ]; then
    clean=$(echo "$selected" | sed "s/$(printf '\033')\[[0-9;]*m//g")
    target=$(echo "$clean" | grep -oE '[a-zA-Z0-9_-]+:[0-9]+' | head -1)

    if [ -n "$target" ]; then
        tmux switch-client -t "$target"
    else
        first=$(echo "$clean" | awk '{print $1}')
        if [ "$first" = "▶" ] || [ "$first" = "▼" ]; then
            session=$(echo "$clean" | awk '{print $2}')
            first_win=$(tmux list-windows -t "$session" -F "#{session_name}:#{window_index}" 2>/dev/null | head -1)
            [ -n "$first_win" ] && tmux switch-client -t "$first_win"
        fi
    fi
fi
