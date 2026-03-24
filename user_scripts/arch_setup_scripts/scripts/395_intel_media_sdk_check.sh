#!/usr/bin/env bash
# INTEL MEDIA DRIVER/SDK SELECTOR (5th Gen to Current)
# Optimized for Bash 5.3+ / Arch Linux / Hyprland ecosystem

# 1. Safety & Strict Mode
set -euo pipefail

# 2. Privileges Check
if (( EUID != 0 )); then
    printf "\e[0;31m[ERROR]\e[0m This script must be run as root.\n" >&2
    exit 1
fi

# 3. Colors
readonly GREEN=$'\e[0;32m'
readonly YELLOW=$'\e[0;33m'
readonly BLUE=$'\e[0;34m'
readonly RED=$'\e[0;31m'
readonly BOLD=$'\e[1m'
readonly RESET=$'\e[0m'

# Global flag for autonomous execution
AUTO_MODE=0

detect_and_install() {
    printf "%s>>> ANALYZING SYSTEM HARDWARE...%s\n" "${BLUE}" "${RESET}"

    # --- STAGE 1: HARDWARE VERIFICATION (The "Horse") ---
    # Execute the raw PCI bus check BEFORE parsing the CPU string.
    # If there is no Intel iGPU, we exit immediately. Zero wasted cycles.
    local intel_gpu_present=0
    local pci_dev vendor class

    shopt -s nullglob
    for pci_dev in /sys/bus/pci/devices/*; do
        if [[ -f "$pci_dev/vendor" && -f "$pci_dev/class" ]]; then
            read -r vendor < "$pci_dev/vendor"
            read -r class < "$pci_dev/class"

            # Vendor 0x8086 = Intel. Class 0x030000 = VGA, 0x038000 = Display
            if [[ "$vendor" == "0x8086" ]] && [[ "$class" == 0x0300* || "$class" == 0x0380* ]]; then
                intel_gpu_present=1
                break
            fi
        fi
    done
    shopt -u nullglob

    if (( ! intel_gpu_present )); then
        printf "%s[SKIP]%s No Intel iGPU detected on the PCI bus.\n" "${YELLOW}" "${RESET}"
        printf "%s[SKIP]%s Skipping installation to prevent bloat on F-series/headless configurations.\n" "${YELLOW}" "${RESET}"
        return 0
    fi

    # --- STAGE 2: MICROARCHITECTURE PARSING (The "Cart") ---
    # Slurp the file entirely into memory (Zero subshells)
    local cpuinfo
    cpuinfo=$(< /proc/cpuinfo) || {
        printf "%s[ERROR]%s Failed to read /proc/cpuinfo.\n" "${RED}" "${RESET}"
        exit 1
    }

    local model_name="${cpuinfo#*model name*: }"
    model_name="${model_name%%$'\n'*}"

    printf "%s[INFO]%s Detected CPU: %s%s%s\n" "${BLUE}" "${RESET}" "${BOLD}" "${model_name}" "${RESET}"

    local gen="" sku

    # Standard Core i-series formats (e.g., i7-8550U, i9-14900K)
    if [[ $model_name =~ i[3579]-([0-9]{4,5})[A-Za-z0-9]* ]]; then
        sku="${BASH_REMATCH[1]}"
        if [[ $sku == 1[0-9]* ]]; then
            gen="${sku:0:2}"
        else
            gen="${sku:0:1}"
        fi
    # Meteor/Lunar/Arrow Lake (e.g., Intel(R) Core(TM) Ultra 7 155H, Core(TM) 5 120U)
    elif [[ $model_name =~ Core\(TM\)[[:space:]](Ultra[[:space:]])?[3579][[:space:]][12][0-9]{2}[A-Za-z]* ]]; then
        gen="14"
    # Alder Lake-N / Modern N-Series Core branding (e.g., Intel(R) Core(TM) i3-N305)
    elif [[ $model_name =~ Core\(TM\)[[:space:]]i[3579]-N[0-9]{3}[A-Za-z0-9]* ]]; then
        gen="12"
    # Alder Lake-N / Modern N-Series Processor branding (e.g., Intel(R) Processor N100)
    elif [[ $model_name =~ Processor[[:space:]]N[0-9]{2,3} ]]; then
        gen="12"
    # Consolidated Core M / m-series / Y-series formats (e.g., m3-6Y30, M-5Y71, i7-7Y75)
    elif [[ $model_name =~ ([mM][357]?|i[3579])[-[:space:]]?((1[0-9]|[5-9])Y[0-9]{2})[A-Za-z0-9]* ]]; then
        gen="${BASH_REMATCH[2]}"
    # Lakefield formats (e.g., i5-L16G7)
    elif [[ $model_name =~ i[35]-L[0-9]{2}G[0-9][A-Za-z0-9]* ]]; then
        gen="10"
    fi

    # --- STAGE 3: DRIVER POLICY & DEPLOYMENT ---
    if [[ -n "$gen" ]]; then
        local target_pkg=""
        local driver_tier=""

        # Restored precise architecture mapping to prevent legacy regressions
        if (( gen >= 12 )); then
            target_pkg="intel-media-driver"
            driver_tier="12th+ Gen (iHD)"
        elif (( gen >= 5 && gen <= 11 )); then
            target_pkg="intel-media-sdk"
            driver_tier="5th-11th Gen (Legacy)"
        else
            printf "%s[SKIP]%s Intel %s Gen CPU detected. Hardware is outside the 5th+ Gen support matrix.\n" "${YELLOW}" "${RESET}" "${gen}"
            return 0
        fi

        printf "%s[MATCH]%s Intel %s graphics hardware present. Target: %s%s%s\n" "${GREEN}" "${RESET}" "${driver_tier}" "${BOLD}" "${target_pkg}" "${RESET}"

        if (( ! AUTO_MODE )); then
            printf "%s[PROMPT]%s Install %s? [Y/n]: " "${YELLOW}" "${RESET}" "${target_pkg}"
            local confirm
            if ! IFS= read -r confirm; then
                printf "\n%s[INFO]%s No input received. Installation aborted.\n" "${BLUE}" "${RESET}"
                return 0
            fi
            if [[ "${confirm,,}" =~ ^(n|no)$ ]]; then
                printf "%s[INFO]%s Installation aborted by user.\n" "${BLUE}" "${RESET}"
                return 0
            fi
        fi

        printf "%s[RUN]%s Deploying %s...\n" "${YELLOW}" "${RESET}" "${target_pkg}"
        pacman -S --needed --noconfirm "${target_pkg}"

        printf "%s[SUCCESS]%s Hardware acceleration stack installed.\n" "${GREEN}" "${RESET}"
        return 0

    elif [[ $model_name =~ Intel ]]; then
        printf "%s[WARN]%s Intel GPU detected, but cannot definitively parse microarchitecture generation.\n" "${YELLOW}" "${RESET}"
        printf "%s[SKIP]%s Skipping installation to prevent driver mismatch.\n" "${YELLOW}" "${RESET}"
    else
        printf "%s[SKIP]%s Non-Intel CPU detected. Module ignored.\n" "${YELLOW}" "${RESET}"
    fi
}

main() {
    for arg in "$@"; do
        if [[ "$arg" == "--auto" || "$arg" == "-a" ]]; then
            AUTO_MODE=1
            break
        fi
    done

    if (( AUTO_MODE )); then
        printf "%s[INFO]%s Autonomous deployment initialized. Suppressing user prompts.\n" "${BLUE}" "${RESET}"
    fi

    detect_and_install
}

main "$@"
