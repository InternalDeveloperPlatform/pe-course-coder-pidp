#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# postCreateCommand.sh - Fast foreground init (~15s)
#
# Gets you a shell ASAP. All heavy lifting runs in setup-background.sh.
# Run `setup-status` to check progress, `setup-status -f` for live logs.
# ============================================================================

SETUP_DIR="/tmp/pidp-setup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_as_root() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

# --- Essential packages (the only apt-get that blocks the shell) ---
run_as_root apt-get update -y
run_as_root apt-get install -y curl unzip wget net-tools jq bash-completion

# --- Directories ---
mkdir -p "$HOME/.kube" "$SETUP_DIR"

# --- Shell config (bashrc entries) ---
# kubectl completion and aliases, git config
# Use a marker so we don't append duplicates on rebuild
if ! grep -q "# pidp-shell-config" "$HOME/.bashrc" 2>/dev/null; then
  cat >> "$HOME/.bashrc" << 'BASHRC'
# pidp-shell-config
source <(kubectl completion bash 2>/dev/null) || true
complete -F __start_kubectl k 2>/dev/null || true
alias k='kubectl'
alias kg='kubectl get'
alias h='humctl'
alias sk='score-k8s'
git config --global user.name "giteaAdmin"
git config --global credential.helper store
BASHRC
fi

# --- Make setup-status available ---
chmod +x "$SCRIPT_DIR/setup-status"
run_as_root ln -sf "$SCRIPT_DIR/setup-status" /usr/local/bin/setup-status

# --- Launch background setup ---
# Env vars must be explicitly available to the nohup subshell
export HUMANITEC_ORG="${HUMANITEC_ORG:-}"
export HUMANITEC_SERVICE_USER="${HUMANITEC_SERVICE_USER:-}"
export PIDP_CERT="${PIDP_CERT:-}"
export PIDP_KEY="${PIDP_KEY:-}"

nohup "$SCRIPT_DIR/setup-background.sh" > "$SETUP_DIR/setup.log" 2>&1 &
BG_PID=$!
echo "$BG_PID" > "$SETUP_DIR/bg.pid"

echo ""
echo "========================================================"
echo "  Shell ready. Background setup running (PID $BG_PID)."
echo "  Run 'setup-status' to check progress."
echo "  Run 'setup-status -f' to tail live logs."
echo "========================================================"
