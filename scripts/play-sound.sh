#!/usr/bin/env bash

# Shared notification sound player for tmux-agent-status
# Reads @agent-notification-sound from tmux options and plays the appropriate sound.
# Falls back to @claude-notification-sound for backwards compatibility.
# Usage: play-sound.sh [wait|done] [&]
# "wait" uses @agent-wait-sound (default: Basso on Mac, dialog-warning on Linux)
# "done" or no arg uses @agent-notification-sound (default: chime)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ensure PulseAudio/PipeWire environment is available (hooks may lack user env)
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
: "${DISPLAY:=:0}"
export XDG_RUNTIME_DIR DISPLAY

SOUND_TYPE="${1:-done}"

if [ "$SOUND_TYPE" = "wait" ]; then
    SOUND_CHOICE=$(tmux show-option -gqv @agent-wait-sound 2>/dev/null)
    : "${SOUND_CHOICE:=alert}"
elif [ "$SOUND_TYPE" = "ask" ]; then
    SOUND_CHOICE=$(tmux show-option -gqv @agent-ask-sound 2>/dev/null)
    : "${SOUND_CHOICE:=chime}"
else
    SOUND_CHOICE=$(tmux show-option -gqv @agent-notification-sound 2>/dev/null)
    [ -z "$SOUND_CHOICE" ] && SOUND_CHOICE=$(tmux show-option -gqv @claude-notification-sound 2>/dev/null)
    : "${SOUND_CHOICE:=chime}"
fi

case "$SOUND_CHOICE" in
    none)
        # Still show notification even if sound is disabled
        ;;
esac

# Desktop notification (optional, requires terminal-notifier on macOS: brew install terminal-notifier)
NOTIFY_ENABLED=$(tmux show-option -gqv @agent-notification-popup 2>/dev/null)
: "${NOTIFY_ENABLED:=on}"
if [ "$NOTIFY_ENABLED" != "off" ]; then
    TMUX_TARGET="${TMUX_PANE:+-t $TMUX_PANE}"
    SESSION_NAME=$(tmux display-message -p $TMUX_TARGET '#{session_name}' 2>/dev/null)
    WINDOW_INDEX=$(tmux display-message -p $TMUX_TARGET '#{window_index}' 2>/dev/null)
    WINDOW_NAME=$(tmux display-message -p $TMUX_TARGET '#{window_name}' 2>/dev/null)
    if [ "$SOUND_TYPE" = "wait" ]; then
        NOTIFY_TITLE="Agent needs permission"
    elif [ "$SOUND_TYPE" = "ask" ]; then
        NOTIFY_TITLE="Agent is asking a question"
    else
        NOTIFY_TITLE="Agent finished"
    fi
    NOTIFY_MSG="${SESSION_NAME}:${WINDOW_INDEX} ${WINDOW_NAME}"
    TMUX_BIN=$(command -v tmux)
    # open the terminal app (whatever it is) then switch to the window
    SWITCH_CMD="open -a '${TERM_PROGRAM:-Terminal}'; $TMUX_BIN switch-client -t '${SESSION_NAME}:${WINDOW_INDEX}'"

    if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "$NOTIFY_TITLE" -message "$NOTIFY_MSG" -group "tmux-agent-status-${SESSION_NAME}-${WINDOW_INDEX}" -execute "$SWITCH_CMD" 2>/dev/null &
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send "$NOTIFY_TITLE" "$NOTIFY_MSG" 2>/dev/null &
    fi
fi

[ "$SOUND_CHOICE" = "none" ] && exit 0

# Map choice to sound files
# Bundled sounds live in $PLUGIN_DIR/sounds/; system sounds used as fallback
case "$SOUND_CHOICE" in
    alert)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/dialog-warning.oga"
        MAC_SOUND="Basso.aiff"
        ;;
    speech)
        BUNDLED_SOUND="$PLUGIN_DIR/sounds/speech.wav"
        LINUX_SOUND=""
        MAC_SOUND=""
        ;;
    bell)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/bell.oga"
        MAC_SOUND="Ping.aiff"
        ;;
    fanfare)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/dialog-information.oga"
        MAC_SOUND="Hero.aiff"
        ;;
    frog)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/phone-incoming-call.oga"
        MAC_SOUND="Frog.aiff"
        ;;
    chime)
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/complete.oga"
        MAC_SOUND="Glass.aiff"
        ;;
    *)
        # unrecognised value falls back to chime
        LINUX_SOUND="/usr/share/sounds/freedesktop/stereo/complete.oga"
        MAC_SOUND="Glass.aiff"
        ;;
esac

# Run sound players in foreground - callers background this script with &
if [ -n "${BUNDLED_SOUND:-}" ] && [ -f "$BUNDLED_SOUND" ]; then
    if command -v paplay >/dev/null 2>&1; then
        paplay "$BUNDLED_SOUND" 2>/dev/null
    elif command -v afplay >/dev/null 2>&1; then
        afplay "$BUNDLED_SOUND" 2>/dev/null
    elif command -v aplay >/dev/null 2>&1; then
        aplay "$BUNDLED_SOUND" 2>/dev/null
    fi
elif command -v paplay >/dev/null 2>&1 && [ -f "$LINUX_SOUND" ]; then
    paplay "$LINUX_SOUND" 2>/dev/null
elif command -v afplay >/dev/null 2>&1; then
    afplay "/System/Library/Sounds/$MAC_SOUND" 2>/dev/null
elif command -v beep >/dev/null 2>&1; then
    beep 2>/dev/null
else
    echo -ne '\a'
fi

exit 0
