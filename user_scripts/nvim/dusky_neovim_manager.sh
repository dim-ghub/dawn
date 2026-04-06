#!/usr/bin/env bash
# ==============================================================================
#  DUSKY NEOVIM MANAGER
# ==============================================================================
#  Target: Arch Linux | Bash 5.3.9+ | Wayland/Hyprland ecosystem
#  Purpose: Elite Neovim configuration deployer, state manager, and synchronizer.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# Visual Formatting & Logging (ANSI-C Quoting)
# ==============================================================================
declare -r GREEN=$'\033[0;32m'
declare -r BLUE=$'\033[0;34m'
declare -r RED=$'\033[0;31m'
declare -r YELLOW=$'\033[0;33m'
declare -r BOLD=$'\033[1m'
declare -r RESET=$'\033[0m'

log_info()    { printf "%s[INFO]%s %s\n" "${BLUE}" "${RESET}" "$1"; }
log_success() { printf "%s[SUCCESS]%s %s\n" "${GREEN}" "${RESET}" "$1"; }
log_warn()    { printf "%s[WARN]%s %s\n" "${YELLOW}" "${RESET}" "$1"; }
log_error()   { printf "%s[ERROR]%s %s\n" "${RED}" "${RESET}" "$1"; }

# ==============================================================================
# Configuration & Globals
# ==============================================================================
readonly BACKUP_DIR="${HOME}/.local/share/nvim_backups"
readonly DUSKY_SRC="${XDG_CONFIG_HOME:-$HOME/.config}/dawn_nvim"

declare -A NVIM_PATHS=(
    [config]="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
    [data]="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
    [state]="${XDG_STATE_HOME:-$HOME/.local/state}/nvim"
    [cache]="${XDG_CACHE_HOME:-$HOME/.cache}/nvim"
)

CURRENT_BACKUP_PATH=""

# ==============================================================================
# Initialization & Traps
# ==============================================================================

cleanup_on_exit() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 && -n "${CURRENT_BACKUP_PATH}" && -d "${CURRENT_BACKUP_PATH}" ]]; then
        echo ""
        log_warn "Deployment interrupted. Your previous state is backed up at:"
        printf "  ${BLUE}%s${RESET}\n" "${CURRENT_BACKUP_PATH}"
    fi
    exit "${exit_code}"
}

trap cleanup_on_exit INT TERM EXIT

check_dependencies() {
    local missing_deps=()
    local cmd
    for cmd in git nvim timeout; do
        if ! command -v "${cmd}" &>/dev/null; then
            missing_deps+=("${cmd}")
        fi
    done

    if (( ${#missing_deps[@]} > 0 )); then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_info "Please install them before running this manager."
        trap - INT TERM EXIT
        exit 1
    fi
}

# ==============================================================================
# State Management (Backup, Wipe, Restore, Reset)
# ==============================================================================

backup_neovim_state() {
    local has_data=false key dir

    for key in "${!NVIM_PATHS[@]}"; do
        if [[ -d "${NVIM_PATHS[$key]}" ]]; then
            has_data=true
            break
        fi
    done

    if ! ${has_data}; then
        log_info "No existing Neovim directories found. Skipping backup."
        return 0
    fi

    local timestamp
    timestamp="${EPOCHSECONDS}"
    CURRENT_BACKUP_PATH="${BACKUP_DIR}/backup_${timestamp}"

    log_info "Creating structured backup at ${CURRENT_BACKUP_PATH}..."
    mkdir -p "${CURRENT_BACKUP_PATH}"

    for key in "${!NVIM_PATHS[@]}"; do
        dir="${NVIM_PATHS[$key]}"
        if [[ -d "${dir}" ]]; then
            mv "${dir}" "${CURRENT_BACKUP_PATH}/${key}"
            printf "  ${GREEN}✓${RESET} Backed up: %s -> %s\n" "${dir}" "${key}"
        fi
    done
}

wipe_neovim_state() {
    local key dir
    log_warn "Surgically wiping current Neovim state..."
    for key in "${!NVIM_PATHS[@]}"; do
        dir="${NVIM_PATHS[$key]}"
        if [[ -d "${dir}" ]]; then
            rm -rf "${dir}"
            printf "  ${RED}✗${RESET} Deleted: %s\n" "${dir}"
        fi
    done
}

reset_neovim_state() {
    local key dir
    log_warn "Surgically wiping Neovim data, state, and cache..."
    for key in "${!NVIM_PATHS[@]}"; do
        if [[ "${key}" == "config" ]]; then
            continue # Shield the configuration directory
        fi
        dir="${NVIM_PATHS[$key]}"
        if [[ -d "${dir}" ]]; then
            rm -rf "${dir}"
            printf "  ${RED}✗${RESET} Deleted: %s\n" "${dir}"
        fi
    done
    log_success "State reset successfully. Configuration preserved."
}

restore_neovim_state() {
    if [[ ! -d "${BACKUP_DIR}" ]]; then
        log_warn "Backup directory does not exist: ${BACKUP_DIR}"
        return 1
    fi

    local available_backups
    mapfile -t available_backups < <(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name 'backup_*' -printf "%f\n" 2>/dev/null | sort -r)

    if (( ${#available_backups[@]} == 0 )); then
        log_warn "No backups found in ${BACKUP_DIR}."
        return 1
    fi

    echo ""
    log_info "Available Backups:"
    
    local original_ps3="${PS3:-}"
    local original_columns="${COLUMNS:-}"
    
    PS3="${BOLD}${YELLOW}Select a backup to restore: ${RESET}"
    COLUMNS=1
    
    local restore_status=1

    select backup_name in "${available_backups[@]}" "Cancel"; do
        if [[ "${backup_name}" == "Cancel" ]]; then
            log_info "Restore cancelled."
            restore_status=1
            break
        elif [[ -n "${backup_name}" ]]; then
            local target_backup="${BACKUP_DIR}/${backup_name}"
            
            log_warn "You are about to restore an older state."
            prompt_state_management
            
            log_info "Initiating restore from ${backup_name}..."
            
            local key dir restored_count=0
            for key in "${!NVIM_PATHS[@]}"; do
                dir="${NVIM_PATHS[$key]}"
                if [[ -d "${target_backup}/${key}" ]]; then
                    mkdir -p "${dir}"
                    cp -a "${target_backup}/${key}/." "${dir}/"
                    printf "  ${GREEN}✓${RESET} Restored: %s\n" "${dir}"
                    restored_count=$((restored_count + 1))
                fi
            done
            
            if (( restored_count > 0 )); then
                log_success "Restore completed successfully (${restored_count} components)."
                restore_status=0
            else
                log_error "Selected backup was empty. Nothing was restored."
                restore_status=1
            fi
            break
        else
            log_error "Invalid selection."
        fi
    done
    
    PS3="${original_ps3}"
    COLUMNS="${original_columns}"
    return "${restore_status}"
}

# ==============================================================================
# Installation Handlers
# ==============================================================================

install_nvchad() {
    log_info "Deploying NvChad..."
    mkdir -p "${NVIM_PATHS[config]}"
    git clone --depth 1 https://github.com/NvChad/starter "${NVIM_PATHS[config]}"
    rm -rf "${NVIM_PATHS[config]}/.git"
    log_success "NvChad deployed."
}

install_lazyvim() {
    log_info "Deploying LazyVim..."
    mkdir -p "${NVIM_PATHS[config]}"
    git clone --depth 1 https://github.com/LazyVim/starter "${NVIM_PATHS[config]}"
    rm -rf "${NVIM_PATHS[config]}/.git"
    log_success "LazyVim deployed."
}

install_astronvim() {
    log_info "Deploying AstroNvim..."
    mkdir -p "${NVIM_PATHS[config]}"
    git clone --depth 1 https://github.com/AstroNvim/template "${NVIM_PATHS[config]}"
    rm -rf "${NVIM_PATHS[config]}/.git"
    log_success "AstroNvim deployed."
}

install_dawn_nvim() {
    log_info "Deploying Dusky Neovim..."
    if [[ ! -d "${DUSKY_SRC}" ]]; then
        log_error "Dusky Neovim source not found at ${DUSKY_SRC}"
        exit 1
    fi
    mkdir -p "${NVIM_PATHS[config]}"
    cp -a "${DUSKY_SRC}/." "${NVIM_PATHS[config]}/"
    log_success "Dusky Neovim deployed precisely."
}

# ==============================================================================
# Synchronization & Interactive Logic
# ==============================================================================

execute_headless_sync() {
    log_info "Verifying network connectivity..."
    if ! timeout 2 bash -c '</dev/tcp/github.com/443' &>/dev/null; then
        log_error "Cannot establish TCP connection to GitHub. Skipping headless sync."
        return 1
    else
        log_info "Starting Headless Sync. This may take a moment..."
        echo "--------------------------------------------------------------------------------"
        if nvim --headless "+Lazy! sync" +qa; then
            echo "--------------------------------------------------------------------------------"
            log_success "Neovim plugins synced successfully."
        else
            echo "--------------------------------------------------------------------------------"
            log_error "Neovim exited with an error code during sync."
        fi
    fi
}

prompt_state_management() {
    echo ""
    log_warn "Proceeding will remove your current Neovim configuration."
    
    local original_ps3="${PS3:-}"
    local original_columns="${COLUMNS:-}"
    
    PS3="${BOLD}${YELLOW}State Management (1-3): ${RESET}"
    COLUMNS=1
    
    local state_handled=false
    local opt
    
    select opt in "Backup existing configuration" "Wipe existing configuration (No Backup)" "Cancel"; do
        case "${REPLY}" in
            1) backup_neovim_state; state_handled=true; break ;;
            2) wipe_neovim_state; state_handled=true; break ;;
            3) 
                log_info "Aborting deployment."
                trap - INT TERM EXIT 
                exit 0 
                ;;
            *) log_error "Invalid option. Select 1-3." ;;
        esac
    done
    
    if ! ${state_handled}; then
        log_error "Input terminated. Aborting."
        trap - INT TERM EXIT
        exit 1
    fi
    
    PS3="${original_ps3}"
    COLUMNS="${original_columns}"
}

prompt_reset_management() {
    echo ""
    log_warn "Proceeding will remove your Neovim data, state, and cache directories."
    log_info "Your main configuration (~/.config/nvim) will NOT be touched."
    
    local original_ps3="${PS3:-}"
    local original_columns="${COLUMNS:-}"
    
    PS3="${BOLD}${YELLOW}Reset State? (1-3): ${RESET}"
    COLUMNS=1
    
    local state_handled=false
    local opt
    local reset_status=1
    
    select opt in "Backup before reset (Includes config)" "Wipe state directly (No Backup)" "Cancel"; do
        case "${REPLY}" in
            1) backup_neovim_state; reset_neovim_state; state_handled=true; reset_status=0; break ;;
            2) reset_neovim_state; state_handled=true; reset_status=0; break ;;
            3) 
                log_info "Reset cancelled."
                state_handled=true
                reset_status=1
                break 
                ;;
            *) log_error "Invalid option. Select 1-3." ;;
        esac
    done
    
    if ! ${state_handled}; then
        log_error "Input terminated. Aborting."
        trap - INT TERM EXIT
        exit 1
    fi
    
    PS3="${original_ps3}"
    COLUMNS="${original_columns}"
    return "${reset_status}"
}

prompt_headless_sync() {
    echo ""
    log_info "Do you want to run headless plugin synchronization now?"
    
    local original_ps3="${PS3:-}"
    local original_columns="${COLUMNS:-}"
    
    PS3="${BOLD}${YELLOW}Sync Plugins? (1-2): ${RESET}"
    COLUMNS=1
    
    local sync_handled=false
    local opt

    select opt in "Yes, sync plugins via Lazy.nvim" "No, skip for now"; do
        case "${REPLY}" in
            1) 
                sync_handled=true
                execute_headless_sync
                break
                ;;
            2) sync_handled=true; break ;;
            *) log_error "Invalid option. Select 1-2." ;;
        esac
    done

    if ! ${sync_handled}; then
        log_warn "Input terminated during sync prompt. Proceeding to launch."
    fi
    
    PS3="${original_ps3}"
    COLUMNS="${original_columns}"
}

# ==============================================================================
# Main Interface
# ==============================================================================

main() {
    check_dependencies
    
    clear
    printf "${BOLD}====================================================${RESET}\n"
    printf "${BOLD}               Dusky Neovim Manager                 ${RESET}\n"
    printf "${BOLD}====================================================${RESET}\n\n"

    local original_columns="${COLUMNS:-}"
    COLUMNS=1
    
    local action_taken=false
    local skip_sync_prompt=false
    local nvim_config
    
    PS3="${BOLD}${YELLOW}Select an operation (1-6): ${RESET}"
    select nvim_config in "Install NvChad" "Install LazyVim" "Install AstroNvim" "Install Dusky Neovim" "Maintenance & Utilities" "Quit"; do
        case "${REPLY}" in
            1) prompt_state_management; install_nvchad; action_taken=true; break ;;
            2) prompt_state_management; install_lazyvim; action_taken=true; break ;;
            3) prompt_state_management; install_astronvim; action_taken=true; break ;;
            4) prompt_state_management; install_dawn_nvim; action_taken=true; break ;;
            5) 
                echo ""
                local main_ps3="${PS3}"
                PS3="${BOLD}${YELLOW}Select a utility (1-5): ${RESET}"
                
                select util in "Backup Current Configuration" "Restore Backup" "Sync Plugins" "Reset State (Keep Config)" "Back to Main Menu"; do
                    case "${REPLY}" in
                        1)
                            echo ""
                            backup_neovim_state
                            echo ""
                            REPLY=""
                            continue
                            ;;
                        2)
                            if restore_neovim_state; then
                                action_taken=true
                                break 2 # Breaks out of both Utility and Main Menu loops
                            else
                                REPLY=""
                                continue
                            fi
                            ;;
                        3)
                            echo ""
                            execute_headless_sync
                            action_taken=true
                            skip_sync_prompt=true
                            break 2
                            ;;
                        4)
                            if prompt_reset_management; then
                                action_taken=true
                                break 2
                            else
                                REPLY=""
                                continue
                            fi
                            ;;
                        5)
                            echo ""
                            break # Exits the Utility menu loop
                            ;;
                        *) log_error "Invalid option. Select 1-5." ;;
                    esac
                done
                
                # Restore Main Menu environment and redraw
                PS3="${main_ps3}"
                REPLY=""
                continue
                ;; 
            6) 
                log_info "Exiting gracefully."
                trap - INT TERM EXIT
                exit 0 
                ;;
            *) log_error "Invalid option. Select 1-6." ;;
        esac
    done
    
    if ! ${action_taken}; then
        log_error "Input terminated. Exiting."
        trap - INT TERM EXIT
        exit 1
    fi

    COLUMNS="${original_columns}"

    if ! ${skip_sync_prompt}; then
        prompt_headless_sync
    fi

    trap - INT TERM EXIT
    echo ""
    log_success "Operations complete. Bootstrapping Neovim..."
    sleep 1
    
    exec nvim
}

# Execute
main "$@"
