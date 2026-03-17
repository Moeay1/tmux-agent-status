#!/usr/bin/env bash

# Claude Code hook for tmux-agent-status
# Updates tmux session status files based on Claude's working state

STATUS_DIR="$HOME/.cache/tmux-agent-status"
mkdir -p "$STATUS_DIR"

# Read JSON from stdin (required by Claude Code hooks)
JSON_INPUT=$(cat)

# Get tmux session if in tmux OR if we're in an SSH session
if [ -n "$TMUX" ] || [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
    # Try to get session name via tmux command first
    # Use TMUX_PANE to target the correct pane (not the currently focused window)
    TMUX_TARGET="${TMUX_PANE:+-t $TMUX_PANE}"
    TMUX_SESSION=$(tmux display-message -p $TMUX_TARGET '#{session_name}' 2>/dev/null)
    TMUX_WINDOW=$(tmux display-message -p $TMUX_TARGET '#{window_index}' 2>/dev/null)
    [ -z "$TMUX_WINDOW" ] && TMUX_WINDOW="0"

    # If that fails (e.g., when called from Claude hooks or over SSH)
    if [ -z "$TMUX_SESSION" ]; then
        # For SSH sessions, try to auto-detect session name from the SSH connection
        if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
            case $(hostname -s) in
                instance-*) TMUX_SESSION="reachgpu" ;;
                keen-schrodinger) TMUX_SESSION="sd1" ;;
                sam-l4-workstation-image) TMUX_SESSION="l4-workstation" ;;
                persistent-faraday) TMUX_SESSION="tig" ;;
                instance-20250620-122051) TMUX_SESSION="reachgpu" ;;
                *) TMUX_SESSION=$(hostname -s) ;;
            esac
        else
            SOCKET_PATH=$(echo "$TMUX" | cut -d',' -f1)
            TMUX_SESSION=$(basename "$SOCKET_PATH")
        fi
    fi

    if [ -n "$TMUX_SESSION" ]; then
        HOOK_TYPE="$1"
        STATUS_FILE="$STATUS_DIR/${TMUX_SESSION}__w${TMUX_WINDOW}.status"
        REMOTE_STATUS_FILE="$STATUS_DIR/${TMUX_SESSION}__w${TMUX_WINDOW}-remote.status"

        # Helper: write status to local and remote files
        write_status() {
            echo "$1" > "$STATUS_FILE"
            if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ]; then
                echo "$1" > "$REMOTE_STATUS_FILE" 2>/dev/null
            fi
        }

        # Helper: auto-rename tmux window based on Claude session info
        try_rename_window() {
            NAME_CACHE="$STATUS_DIR/${TMUX_SESSION}__w${TMUX_WINDOW}.name"
            # Throttle: skip if renamed within last 30 seconds
            if [ -f "$NAME_CACHE" ]; then
                local cache_age
                cache_age=$(( $(date +%s) - $(stat -f %m "$NAME_CACHE" 2>/dev/null || stat -c %Y "$NAME_CACHE" 2>/dev/null || echo 0) ))
                [ "$cache_age" -lt 30 ] && return
            fi
            TRANSCRIPT=$(echo "$JSON_INPUT" | grep -o '"transcript_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"transcript_path"[[:space:]]*:[[:space:]]*"//;s/"//')
            SESSION_ID=$(echo "$JSON_INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"session_id"[[:space:]]*:[[:space:]]*"//;s/"//')
            [ -z "$TRANSCRIPT" ] || [ -z "$SESSION_ID" ] && return

            INDEX_FILE="$(dirname "$TRANSCRIPT")/sessions-index.json"
            WIN_NAME=""

            # Try 1: summary from sessions-index.json
            if [ -f "$INDEX_FILE" ]; then
                WIN_NAME=$(python3 - "$INDEX_FILE" "$SESSION_ID" <<'PYEOF'
import json,sys
with open(sys.argv[1]) as f:
    data=json.load(f)
for e in data.get('entries',[]):
    if e.get('sessionId')==sys.argv[2] and e.get('summary'):
        print(e['summary'][:40])
        break
PYEOF
)
            fi

            # Try 2: custom-title or first user prompt from transcript
            if [ -z "$WIN_NAME" ] && [ -f "$TRANSCRIPT" ]; then
                WIN_NAME=$(python3 - "$TRANSCRIPT" <<'PYEOF'
import json,sys
title=None
first_prompt=None
for line in open(sys.argv[1]):
    try:
        obj=json.loads(line)
    except: continue
    if obj.get('type')=='custom-title' and obj.get('customTitle'):
        title=obj['customTitle']
    if first_prompt is None and obj.get('type')=='user':
        msg=obj.get('message',{}).get('content','')
        if isinstance(msg,list):
            for item in msg:
                if isinstance(item,dict) and item.get('type')=='text':
                    msg=item['text']; break
        if isinstance(msg,str) and len(msg)>=2 and not msg.startswith('[') and not msg.startswith('{"tool_use_id'):
            first_prompt=msg.replace('\n',' ').replace('\r','').strip()[:40]
if title:
    print(title[:40])
elif first_prompt:
    print(first_prompt)
PYEOF
)
            fi

            # Try 3: cwd basename
            if [ -z "$WIN_NAME" ]; then
                CWD=$(echo "$JSON_INPUT" | grep -o '"cwd"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"cwd"[[:space:]]*:[[:space:]]*"//;s/"//')
                [ -n "$CWD" ] && WIN_NAME=$(basename "$CWD")
            fi

            # Only rename if we got a name and it differs from cached
            if [ -n "$WIN_NAME" ]; then
                CACHED=$(cat "$NAME_CACHE" 2>/dev/null)
                if [ "$WIN_NAME" != "$CACHED" ]; then
                    echo "$WIN_NAME" > "$NAME_CACHE"
                    tmux rename-window -t "${TMUX_SESSION}:${TMUX_WINDOW}" "$WIN_NAME" 2>/dev/null
                fi
            fi
        }

        case "$HOOK_TYPE" in
            "UserPromptSubmit")
                write_status "working"
                try_rename_window
                ;;
            "PreToolUse")
                TOOL_NAME=$(echo "$JSON_INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"tool_name"[[:space:]]*:[[:space:]]*"//;s/"//')
                if [ "$TOOL_NAME" = "AskUserQuestion" ]; then
                    write_status "ask"
                    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                    "$SCRIPT_DIR/../scripts/play-sound.sh" ask 2>/dev/null &
                else
                    write_status "working"
                fi
                try_rename_window
                ;;
            "Stop")
                write_status "done"
                try_rename_window
                ;;
            "Notification")
                CURRENT=$(cat "$STATUS_FILE" 2>/dev/null)
                if [ "$CURRENT" != "wait" ] && [ "$CURRENT" != "ask" ]; then
                    write_status "done"
                    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                    "$SCRIPT_DIR/../scripts/play-sound.sh" 2>/dev/null &
                fi
                ;;
            "PermissionRequest")
                write_status "wait"
                SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
                "$SCRIPT_DIR/../scripts/play-sound.sh" wait 2>/dev/null &
                ;;
        esac
    fi
fi

# Always exit successfully
exit 0
