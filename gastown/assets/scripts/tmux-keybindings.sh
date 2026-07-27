#!/bin/sh
# tmux-keybindings.sh — Gas Town navigation keybindings (n/p/g/a + mail click)
# Usage: tmux-keybindings.sh <config-dir>
CONFIGDIR="$1"

# Socket-aware tmux command (uses GC_TMUX_SOCKET when set).
gcmux() { tmux ${GC_TMUX_SOCKET:+-L "$GC_TMUX_SOCKET"} "$@"; }

# ── Navigation bindings (prefix table) ────────────────────────────────
"$CONFIGDIR"/assets/scripts/bind-key.sh n "run-shell '$CONFIGDIR/assets/scripts/cycle.sh next #{session_name} #{client_tty}'"
"$CONFIGDIR"/assets/scripts/bind-key.sh p "run-shell '$CONFIGDIR/assets/scripts/cycle.sh prev #{session_name} #{client_tty}'"
"$CONFIGDIR"/assets/scripts/bind-key.sh g "run-shell '$CONFIGDIR/assets/scripts/agent-menu.sh #{client_tty}'"

# ── Mail click binding (root table: left-click on status-right) ───────
# Shows unread mail preview in a popup when clicking the status-right area.
# Per-city socket isolation makes every session on this socket a GC
# session, so we install the popup directly without an if-shell guard.
mail_popup="display-popup -E -w 60 -h 15 'gc mail peek || echo No unread mail'"
existing=$(gcmux list-keys -T root MouseDown1StatusRight 2>/dev/null || true)
if ! printf '%s' "$existing" | grep -qF "$mail_popup"; then
    gcmux bind-key -T root MouseDown1StatusRight "$mail_popup"
fi

# ── Mouse-wheel scrollback (root table) ───────────────────────────────
# Make the wheel drive tmux copy-mode scrollback instead of leaking to the
# focused app. Without this, "mouse on" (set in tmux-theme.sh) hands the wheel
# to mouse-reporting TUIs — Claude Code scrolls its own history, a pager/shell
# gets Up-arrows — and only a bare prompt reaches copy-mode; once in copy-mode
# the wheel passes through (-M) for normal scrolling, and -e exits at the
# bottom. Shift+wheel still does native terminal selection.
#
# LOCAL PATCH 2026-07-27 — mouse_any_flag check restored.
# This line previously forced copy-mode over mouse-reporting apps too ("so
# scrollback wins"). That intent is unreachable on the ALTERNATE SCREEN: a
# full-screen TUI (Claude Code, vim, less) has no tmux scrollback by design, so
# history_size is 0 and the forced copy-mode opens empty — the "[0/0], can't
# scroll" symptom. Measured on a live Claude Code pane: alternate_on=1,
# history_size=0, mouse_any_flag=1.
#
# These bindings are SERVER-GLOBAL and this script runs on every session
# creation, so each new agent session re-applied the force to every pane on the
# socket, including already-running ones.
#
# Kept as mouse_any_flag (not #{alternate_on}, which upstream PR #205 proposes)
# deliberately: it must MATCH ~/.dotfiles/tmux/wheel.conf, which hooks re-source
# on attach/session-created/pane-select. If the two predicates disagree,
# behaviour depends on whichever fired last — the exact silent-drift hazard
# wheel.conf's header warns about. Change both together or neither.
gcmux bind-key -T root WheelUpPane   if-shell -F -t= "#{||:#{pane_in_mode},#{mouse_any_flag}}" "send-keys -M" "copy-mode -e"
gcmux bind-key -T root WheelDownPane send-keys -M
