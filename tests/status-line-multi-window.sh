#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

TEST_HOME="$TMP_DIR/home"
FAKE_BIN="$TMP_DIR/bin"
STATUS_DIR="$TEST_HOME/.cache/tmux-agent-status"

mkdir -p "$FAKE_BIN" "$STATUS_DIR"

cat > "$FAKE_BIN/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
    list-windows)
        printf '%s\n' "myproject:0" "myproject:1" "other:0"
        ;;
    list-panes)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/pgrep" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_BIN/pgrep"

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [ "$expected" != "$actual" ]; then
        echo "Assertion failed: $message" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

run_status_line() {
    PATH="$FAKE_BIN:$PATH" \
    HOME="$TEST_HOME" \
    "$REPO_DIR/scripts/status-line.sh"
}

# Window 0 is working, window 1 is done
echo "working" > "$STATUS_DIR/myproject__w0.status"
echo "done" > "$STATUS_DIR/myproject__w1.status"

output="$(run_status_line)"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default] #[fg=green]✓ 1 done#[default]" "$output" \
    "two windows in same session should be counted independently"

# Both working
echo "working" > "$STATUS_DIR/myproject__w1.status"
output="$(run_status_line)"
assert_eq "#[fg=yellow,bold]⚡ 2 working#[default]" "$output" \
    "two working windows should show count of 2"

# All three done
echo "done" > "$STATUS_DIR/other__w0.status"
echo "done" > "$STATUS_DIR/myproject__w0.status"
echo "done" > "$STATUS_DIR/myproject__w1.status"
output="$(run_status_line)"
assert_eq "#[fg=green,bold]✓ All agents ready#[default]" "$output" \
    "all done windows should show all agents ready"

# Test wait status (permission request)
echo "working" > "$STATUS_DIR/myproject__w0.status"
echo "wait" > "$STATUS_DIR/myproject__w1.status"
rm -f "$STATUS_DIR/other__w0.status"
output="$(run_status_line)"
assert_eq "#[fg=yellow,bold]⚡ agent working#[default] #[fg=magenta,bold]🔔 1 waiting#[default]" "$output" \
    "wait status should render as waiting segment"

# Only wait
rm -f "$STATUS_DIR/myproject__w0.status"
output="$(run_status_line)"
assert_eq "#[fg=magenta,bold]🔔 1 waiting#[default]" "$output" \
    "wait-only should not show as all agents ready"

echo "status-line multi-window regression checks passed"
