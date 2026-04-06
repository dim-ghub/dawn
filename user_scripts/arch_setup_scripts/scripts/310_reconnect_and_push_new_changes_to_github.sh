#!/usr/bin/env bash
# reconnects to an existing github bare repo to sync backup
# ==============================================================================
# ARCH LINUX DOTFILES SYNC
# Context: Hyprland / UWSM / Bash 5+
# Logic: Ask Intent -> Clone Bare -> Reset -> Sync via .git_dawn_list
# ==============================================================================
# Features:
#   1. Forces execution from $HOME so relative paths resolve correctly.
#   2. Supports interactive SSH passphrases with atomic key generation.
#   3. Uses Bash 5+ namerefs for secure input gathering (No 'eval').
#   4. Safely handles completely empty repositories without crashing.
#   5. Ultra-fast, single-execution file staging via secure pathspec.
# ==============================================================================

# 1. STRICT SAFETY
set -euo pipefail
IFS=$'\n\t'

# 2. CONSTANTS
readonly DEFAULT_REPO_NAME="dawn"
readonly DOTFILES_DIR="$HOME/dawn"
readonly DOTFILES_LIST="$HOME/.git_dawn_list"
readonly SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
readonly SSH_DIR="$HOME/.ssh"
readonly REQUIRED_CMDS=(git ssh ssh-keygen ssh-agent ssh-add mktemp)

# 3. VISUALS
readonly BOLD=$'\033[1m'
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly BLUE=$'\033[0;34m'
readonly YELLOW=$'\033[0;33m'
readonly CYAN=$'\033[0;36m'
readonly NC=$'\033[0m'

# 4. RUNTIME STATE
TEMP_KEY_DIR=""
SCRIPT_SSH_AGENT_PID=""
CLEAN_LIST=""

# ==============================================================================
# HELPER FUNCTIONS
# ==============================================================================

log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[OK]${NC}   %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error()   { printf "${RED}[ERR]${NC}  %s\n" "$*" >&2; }
log_fatal()   { log_error "$*"; exit 1; }

# The Git Wrapper
dotgit() {
    /usr/bin/git --git-dir="$DOTFILES_DIR" --work-tree="$HOME" "$@"
}

cleanup() {
    if [[ -n "${SCRIPT_SSH_AGENT_PID:-}" ]]; then
        kill -- "$SCRIPT_SSH_AGENT_PID" >/dev/null 2>&1 || true
    fi

    if [[ -n "${TEMP_KEY_DIR:-}" && -d "${TEMP_KEY_DIR:-}" ]]; then
        rm -rf -- "$TEMP_KEY_DIR"
    fi

    if [[ -n "${CLEAN_LIST:-}" && -f "${CLEAN_LIST:-}" ]]; then
        rm -f -- "$CLEAN_LIST"
    fi
}
trap cleanup EXIT

ask() {
    local prompt="$1"
    local -n out="$2"

    while [[ -z "${out:-}" ]]; do
        read -r -p "   $prompt: " out
    done
}

generate_ssh_key() {
    local key_comment="$1"
    local temp_key

    TEMP_KEY_DIR=$(mktemp -d "$SSH_DIR/.keygen.XXXXXXXX") || \
        log_fatal "Failed to create temporary directory for SSH key generation."

    temp_key="$TEMP_KEY_DIR/id_ed25519"

    if ! ssh-keygen -t ed25519 -C "$key_comment" -f "$temp_key"; then
        log_fatal "SSH key generation failed."
    fi

    mv -f -- "$temp_key" "$SSH_KEY_PATH"
    mv -f -- "$temp_key.pub" "$SSH_KEY_PATH.pub"

    rmdir -- "$TEMP_KEY_DIR"
    TEMP_KEY_DIR=""
}

# ==============================================================================
# PRE-FLIGHT
# ==============================================================================

cd "$HOME" || log_fatal "Could not change directory to HOME."

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
        log_fatal "Missing dependency: $cmd"
    fi
done

# ==============================================================================
# 1. INITIAL PROMPT
# ==============================================================================

clear
printf "${BOLD}Arch Linux Dotfiles Linker${NC}\n"
printf "This script links %s to your GitHub bare repository (No Overwrites).\n\n" "$HOME"

read -r -p "Do you have an existing GitHub repository to commit changes to? (y/N): " HAS_REPO

if [[ ! "$HAS_REPO" =~ ^[yY] ]]; then
    printf "\n"
    log_info "Okay."
    printf "You can do so anytime by running the:\n"
    printf "${CYAN}'0XX_new_github_repo_to_backup.sh'${NC} Script.\n\n"
    log_success "Exiting successfully."
    exit 0
fi

# ==============================================================================
# 2. INPUT GATHERING
# ==============================================================================

printf "\n${BOLD}--- Configuration ---${NC}\n"

printf "${CYAN}1. Identity${NC}\n"
ask "Git User Name (e.g., 'any_name')" GIT_NAME
ask "Git Email (e.g., 'xyz@gmail.com')" GIT_EMAIL

printf "\n${CYAN}2. Repository${NC}\n"
ask "GitHub Username (e.g., 'your_actual_github_name')" GH_USERNAME

printf "${CYAN}Repo Name${NC}\n"
printf "   The name of the repository on GitHub.\n"
read -r -p "   > [Default: $DEFAULT_REPO_NAME]: " INPUT_REPO_NAME
REPO_NAME="${INPUT_REPO_NAME:-$DEFAULT_REPO_NAME}"

printf "\n${CYAN}3. Commit${NC}\n"
ask "Initial Commit Message" COMMIT_MSG

REPO_URL="git@github.com:${GH_USERNAME}/${REPO_NAME}.git"

printf "\n${BOLD}Review Configuration:${NC}\n"
printf '  User:   %s <%s>\n' "$GIT_NAME" "$GIT_EMAIL"
printf '  Repo:   %s\n' "$REPO_URL"
read -r -p "Proceed? (y/N): " CONFIRM
[[ "$CONFIRM" =~ ^[yY] ]] || log_fatal "Aborted by user."

# ==============================================================================
# 3. SSH SETUP
# ==============================================================================

printf "\n${BOLD}--- SSH Configuration ---${NC}\n"

if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p -- "$SSH_DIR"
    chmod 700 "$SSH_DIR"
fi

# Key Generation
if [[ -f "$SSH_KEY_PATH" ]]; then
    log_warn "SSH key exists at $SSH_KEY_PATH"
    read -r -p "   Overwrite? (y/N): " OW
    if [[ "$OW" =~ ^[yY] ]]; then
        generate_ssh_key "$GIT_EMAIL"
        log_success "New key generated."
    else
        log_info "Using existing key."
    fi
else
    generate_ssh_key "$GIT_EMAIL"
    log_success "Key generated."
fi

[[ -f "$SSH_KEY_PATH.pub" ]] || log_fatal "Missing public key: $SSH_KEY_PATH.pub"

# Agent Start
eval "$(ssh-agent -s)" >/dev/null
SCRIPT_SSH_AGENT_PID="$SSH_AGENT_PID"

# Add Key
log_info "Adding SSH key to agent..."
if ! ssh-add "$SSH_KEY_PATH" 2>/dev/null; then
    log_info "Passphrase required. Please enter it now:"
    ssh-add "$SSH_KEY_PATH"
fi

printf "\n${YELLOW}${BOLD}ACTION REQUIRED:${NC} Add this key to GitHub (Settings -> SSH and GPG keys -> New SSH key)\n"
printf "%s\n" "----------------------------------------------------------------"
cat "$SSH_KEY_PATH.pub"
printf "%s\n" "----------------------------------------------------------------"
read -r -p "Press [Enter] once you have added the key to GitHub..."

log_info "Testing connection..."
set +e
ssh -T -o StrictHostKeyChecking=accept-new git@github.com >/dev/null 2>&1
SSH_CODE=$?
set -e

if [[ $SSH_CODE -eq 1 ]]; then
    log_success "GitHub authentication verified."
else
    log_fatal "SSH Connection failed. Exit code: $SSH_CODE"
fi

# ==============================================================================
# 4. REPO SETUP
# ==============================================================================

printf "\n${BOLD}--- Repository Setup ---${NC}\n"

if [[ -e "$DOTFILES_DIR" && ! -d "$DOTFILES_DIR" ]]; then
    log_fatal "Path exists but is not a directory: $DOTFILES_DIR"
fi

if [[ -d "$DOTFILES_DIR" ]]; then
    is_bare_repo="$(git --git-dir="$DOTFILES_DIR" rev-parse --is-bare-repository 2>/dev/null || true)"
    if [[ "$is_bare_repo" == "true" ]]; then
        log_info "Using existing bare repo at $DOTFILES_DIR"
    else
        log_fatal "Refusing to use existing path because it is not a bare Git repository: $DOTFILES_DIR"
    fi
else
    log_info "Cloning bare repo..."
    git clone --bare "$REPO_URL" "$DOTFILES_DIR"
fi

log_info "Configuring local settings..."
dotgit config --local user.name "$GIT_NAME"
dotgit config --local user.email "$GIT_EMAIL"
dotgit config --local status.showUntrackedFiles no

if dotgit remote get-url origin >/dev/null 2>&1; then
    dotgit remote set-url origin "$REPO_URL"
else
    dotgit remote add origin "$REPO_URL"
fi

log_info "Fetching latest refs from origin..."
dotgit fetch --prune origin

if dotgit rev-parse --verify HEAD^{commit} >/dev/null 2>&1; then
    log_info "Resetting index to match HEAD (Mixed Reset)..."
    dotgit reset --mixed --quiet HEAD
else
    log_info "Repository has no commits yet; skipping reset."
fi

log_success "Repository linked. No files were overwritten."

# ==============================================================================
# 5. SYNC & PUSH (OPTIMIZED)
# ==============================================================================

printf "\n${BOLD}--- Final Sync ---${NC}\n"

log_info "Current Git Status:"
dotgit status --short

if [[ -f "$DOTFILES_LIST" ]]; then
    log_info "Processing .git_dawn_list..."

    CLEAN_LIST=$(mktemp)

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ $line == *$'\r' ]] && line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*$ ]] && continue
        [[ $line =~ ^[[:space:]]*# ]] && continue

        if [[ -e "$line" || -L "$line" ]] || dotgit ls-files --error-unmatch -- "$line" >/dev/null 2>&1; then
            printf '%s\n' "$line" >> "$CLEAN_LIST"
        else
            log_warn "Skipping missing untracked path: $line"
        fi
    done < "$DOTFILES_LIST"

    if [[ -s "$CLEAN_LIST" ]]; then
        log_info "Staging validated files..."
        dotgit add --pathspec-from-file="$CLEAN_LIST"
    else
        log_warn "No valid entries found in list. Using standard update (-u)..."
        dotgit add -u
    fi
else
    log_warn ".git_dawn_list not found. Falling back to updating tracked files..."
    dotgit add -u
fi

if ! dotgit diff --cached --quiet; then
    log_info "Committing changes..."
    dotgit commit -m "$COMMIT_MSG"
    log_success "Committed."
else
    log_info "Nothing to commit."
fi

log_info "Ensuring remote origin..."
if dotgit remote get-url origin >/dev/null 2>&1; then
    dotgit remote set-url origin "$REPO_URL"
else
    dotgit remote add origin "$REPO_URL"
fi

if dotgit rev-parse --verify HEAD^{commit} >/dev/null 2>&1; then
    CURRENT_BRANCH=$(dotgit symbolic-ref --quiet --short HEAD)
    log_info "Pushing to $CURRENT_BRANCH..."
    dotgit push -u origin "$CURRENT_BRANCH"
else
    log_info "No commit exists yet; nothing to push."
fi

printf "\n${GREEN}${BOLD}Speedrun Complete.${NC}\n"
