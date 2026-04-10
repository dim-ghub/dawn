#!/usr/bin/env bash
#          Auto sets up SSH
#          iptables/nftables), smart IP/Tailscale detection, sshd.socket aware.
# Target:  Arch Linux (latest), Wayland/Hyprland
# Usage:   ./setup-ssh.sh [--auto|-a] [--help|-h]
# ==============================================================================

# --- 1. Safety & Path Resolution ---
set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_PATH=""
if [[ -f "$0" ]]; then
	SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null) || SCRIPT_PATH=""
	if [[ -n "$SCRIPT_PATH" ]] && [[ ! -f "$SCRIPT_PATH" ]]; then
		SCRIPT_PATH=""
	fi
fi

# --- 2. Argument Parsing ---
AUTO_MODE=false
for arg in "$@"; do
	case "$arg" in
	--auto | -a) AUTO_MODE=true ;;
	--help | -h)
		printf "Usage: %s [--auto|-a] [--help|-h]\n\n" "$(basename "$0")"
		printf "  --auto, -a    Run non-interactively (accept all prompts)\n"
		printf "  --help, -h    Show this help message\n"
		exit 0
		;;
	*)
		printf "Unknown option: %s (try --help)\n" "$arg" >&2
		exit 1
		;;
	esac
done
readonly AUTO_MODE

# --- 3. Colors & Logging ---
if [[ -t 1 ]]; then
	readonly C_RESET=$'\e[0m' C_BOLD=$'\e[1m'
	readonly C_GREEN=$'\e[32m' C_BLUE=$'\e[34m' C_YELLOW=$'\e[33m'
	readonly C_RED=$'\e[31m' C_CYAN=$'\e[36m' C_MAGENTA=$'\e[35m'
else
	readonly C_RESET='' C_BOLD='' C_GREEN='' C_BLUE=''
	readonly C_YELLOW='' C_RED='' C_CYAN='' C_MAGENTA=''
fi

info() { printf "%s[INFO]%s %s\n" "$C_BLUE" "$C_RESET" "$*"; }
success() { printf "%s[OK]%s   %s\n" "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf "%s[WARN]%s %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf "%s[ERR]%s  %s\n" "$C_RED" "$C_RESET" "$*" >&2; }
die() {
	error "$*"
	exit 1
}

cleanup() {
	local exit_code=$?
	if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]]; then
		printf "\n%s[!] Script exited with errors (code %d). Some changes may have been partially applied.%s\n" \
			"$C_RED" "$exit_code" "$C_RESET" >&2
	fi
}
trap cleanup EXIT

# --- Init System ---
readonly INIT_SYSTEM="openrc"

# --- 4. Privilege Escalation ---
if [[ $EUID -ne 0 ]]; then
	if [[ -n "$SCRIPT_PATH" ]] && [[ -f "$SCRIPT_PATH" ]]; then
		exec sudo --preserve-env=TERM,COLORTERM bash -- "$SCRIPT_PATH" "$@"
	else
		die "Root required. Run with: sudo bash $(basename "$0") $*"
	fi
fi

# --- 5. REAL_USER Detection & Validation ---
REAL_USER="${SUDO_USER:-}"

if [[ -z "$REAL_USER" ]]; then
	# MERGED: From Script 1 — filter UID >= 1000 to skip display-manager users
	# (gdm/lightdm/sddm) that loginctl would otherwise return first.
	# loginctl output format: SESSION UID USER SEAT ...
	REAL_USER=$(loginctl list-sessions --no-legend 2>/dev/null |
		awk '$2 >= 1000 {print $3; exit}' || true)
fi

REAL_USER="${REAL_USER:-root}"

if ! id "$REAL_USER" &>/dev/null; then
	warn "Detected user '$REAL_USER' does not exist. Falling back to 'root'."
	REAL_USER="root"
fi

# --- 6. User Confirmation ---
printf "\n%sArch Linux SSH Provisioning%s\n" "$C_BOLD" "$C_RESET"
printf "Provisions: OpenSSH · Firewalls · Tailscale · Network Routes\n\n"

if [[ "$AUTO_MODE" == "true" ]]; then
	info "Autonomous mode — all prompts auto-accepted."
	response="Y"
else
	if ! read -r -p "${C_YELLOW}Enable SSH Access? [Y/n]${C_RESET} " response; then
		die "Cannot read from stdin. Use --auto for non-interactive mode."
	fi
	response=${response:-Y}
fi

if [[ ! "$response" =~ ^[yY]([eE][sS])?$ ]]; then
	info "Aborting at user request."
	exit 0
fi

# --- 7. Package Installation ---
if ! pacman -Qi openssh &>/dev/null; then
	info "Installing OpenSSH..."

	if [[ -f /var/lib/pacman/db.lck ]]; then
		die "Pacman database locked (/var/lib/pacman/db.lck). Is another package manager running?"
	fi

	install_output=""
	if install_output=$(pacman -S --noconfirm --needed openssh 2>&1); then
		success "OpenSSH installed."
	else
		error "Installation failed:"
		printf "%s\n" "$install_output" >&2
		warn "If your package database is stale, run 'sudo pacman -Syu' first."
		die "Refusing partial upgrade (-Sy). Fix the above and re-run."
	fi
else
	success "OpenSSH is already installed."
fi

# --- 8. Host Key Generation ---
info "Ensuring SSH host keys exist..."
if ssh-keygen -A >/dev/null 2>&1; then
	success "SSH host keys verified."
else
	warn "ssh-keygen -A failed. Check permissions on /etc/ssh/."
fi

# --- 9. Config Validation ---
info "Validating sshd configuration..."
config_errors=""
if ! config_errors=$(sshd -t 2>&1); then
	error "sshd configuration is invalid:"
	printf "  %s\n" "$config_errors" >&2
	# FIXED: Typo — was "sshd_confi g" (with space) in both original scripts
	die "Fix /etc/ssh/sshd_config and re-run."
fi
success "sshd configuration is valid."

# --- 10. Unit Detection (sshd.socket vs sshd.service) ---
SSH_UNIT="sshd.service"
SSH_UNIT_TYPE="service"

if systemctl is-active --quiet sshd.socket 2>/dev/null; then
	SSH_UNIT="sshd.socket"
	SSH_UNIT_TYPE="socket"
	info "Detected active sshd.socket (on-demand activation)."
elif systemctl is-enabled --quiet sshd.socket 2>/dev/null; then
	SSH_UNIT="sshd.socket"
	SSH_UNIT_TYPE="socket"
	info "Detected enabled sshd.socket (on-demand activation)."
fi

# --- 11. Port Detection ---
SSH_PORT=""

# Socket-activated: port comes from the unit file, not sshd_config
if [[ "$SSH_UNIT_TYPE" == "socket" ]]; then
	socket_config=$(systemctl cat sshd.socket 2>/dev/null || true)
	if [[ -n "$socket_config" ]]; then
		# ListenStream= can be: "22", "0.0.0.0:22", "[::]:22", or empty (reset)
		# Take the last meaningful value (later directives override earlier)
		# MERGED: From Script 1 — [[:space:]]* handles indented directives in
		# drop-in override files that systemctl cat includes.
		socket_port=$(printf '%s\n' "$socket_config" | awk '
            /^[[:space:]]*ListenStream=/ {
                val = $0
                sub(/^[[:space:]]*ListenStream=/, "", val)
                gsub(/[[:space:]]/, "", val)
                if (val == "") {
                    result = ""
                } else if (match(val, /[0-9]+$/)) {
                    result = substr(val, RSTART, RLENGTH)
                }
            }
            END { if (result != "") print result }
        ' || true)

		if [[ -n "$socket_port" ]] && [[ "$socket_port" =~ ^[0-9]+$ ]]; then
			SSH_PORT="$socket_port"

			# Cross-check against sshd_config
			config_port=$(sshd -T 2>/dev/null |
				awk '/^port / {print $2; exit}' || true)
			if [[ -n "$config_port" ]] && [[ "$config_port" != "$SSH_PORT" ]]; then
				warn "sshd.socket listens on port $SSH_PORT, sshd_config says port $config_port."
				warn "Socket activation uses the socket unit's port ($SSH_PORT)."
			fi
		fi
	fi
fi

# Fallback: sshd_config
if [[ -z "$SSH_PORT" ]]; then
	SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
fi

# Final fallback
if [[ -z "$SSH_PORT" ]] || [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
	SSH_PORT="22"
fi

# FIXED: Validate port range (both originals accepted e.g. "99999")
if [[ "$SSH_PORT" -lt 1 ]] || [[ "$SSH_PORT" -gt 65535 ]]; then
	warn "Detected port $SSH_PORT is outside valid range (1-65535). Falling back to 22."
	SSH_PORT="22"
fi

info "SSH port: $SSH_PORT"

# --- 12. sshd_config Warnings ---
sshd_full_config=$(sshd -T 2>/dev/null || true)

if [[ -n "$sshd_full_config" ]]; then

	# 12a. ListenAddress — warn if only localhost
	listen_addrs=$(printf '%s\n' "$sshd_full_config" |
		awk '/^listenaddress / {print $2}' || true)
	if [[ -n "$listen_addrs" ]]; then
		all_local=true
		while IFS= read -r addr; do
			[[ -z "$addr" ]] && continue
			# Normalize: strip brackets and port suffix so we can pattern-match
			# the bare address against localhost indicators.
			# FIXED: Cleaned up dead code from Script 2 while keeping its correct
			# IPv6 bracket handling (which Script 1 lacked).
			addr_bare="$addr"
			if [[ "$addr_bare" == \[* ]]; then
				# Bracketed IPv6: [::1]:22 → ::1
				addr_bare="${addr_bare#\[}"
				addr_bare="${addr_bare%%\]*}"
			elif [[ "$addr_bare" == *.* ]] && [[ "$addr" == *:* ]]; then
				# IPv4 with port suffix: 127.0.0.1:22 → 127.0.0.1
				# The *.* gate prevents bare IPv6 (::1) from entering this branch,
				# since ::1 contains colons but no dots.
				local_suffix="${addr##*:}"
				if [[ "$local_suffix" =~ ^[0-9]+$ ]]; then
					addr_bare="${addr%:*}"
				fi
			fi
			case "$addr_bare" in
			127.* | ::1 | localhost) ;;
			*)
				all_local=false
				break
				;;
			esac
		done <<<"$listen_addrs"
		if [[ "$all_local" == "true" ]]; then
			warn "sshd listens only on localhost. Remote connections will NOT work."
			# FIXED: Typo — was "sshd_confi g" (with space) in both original scripts
			warn "Check ListenAddress in /etc/ssh/sshd_config."
		fi
	fi

	# 12b. PermitRootLogin — warn if REAL_USER is root
	if [[ "$REAL_USER" == "root" ]]; then
		permit_root=$(printf '%s\n' "$sshd_full_config" |
			awk '/^permitrootlogin / {print $2; exit}' || true)
		case "$permit_root" in
		no)
			warn "PermitRootLogin is 'no'. Root cannot SSH in at all."
			;;
		prohibit-password | without-password)
			warn "PermitRootLogin is '$permit_root'."
			warn "Root login requires SSH keys — password auth won't work for root."
			;;
		esac
	fi

	# 12c. PasswordAuthentication — warn if disabled with no keys
	pass_auth=$(printf '%s\n' "$sshd_full_config" |
		awk '/^passwordauthentication / {print $2; exit}' || true)
	if [[ "$pass_auth" == "no" ]]; then
		user_home=$(getent passwd "$REAL_USER" 2>/dev/null |
			awk -F: '{print $6}' || true)
		if [[ -z "$user_home" ]]; then
			# Fallback for edge cases where getent isn't available
			if [[ "$REAL_USER" == "root" ]]; then
				user_home="/root"
			else
				user_home="/home/${REAL_USER}"
			fi
		fi
		if [[ -n "$user_home" ]] && [[ ! -s "${user_home}/.ssh/authorized_keys" ]]; then
			warn "PasswordAuthentication is disabled and no authorized_keys for '$REAL_USER'."
			warn "Add SSH public keys to ${user_home}/.ssh/authorized_keys before connecting."
		fi
	fi

	# 12d. AllowUsers — warn if set and user not listed
	allow_users=$(printf '%s\n' "$sshd_full_config" |
		awk '/^allowusers / {$1=""; gsub(/^[[:space:]]+/,""); print; exit}' || true)
	if [[ -n "$allow_users" ]]; then
		if ! printf '%s' " ${allow_users} " | grep -q " ${REAL_USER} "; then
			warn "AllowUsers is set (${allow_users}) and may not include '$REAL_USER'."
		fi
	fi

	# 12e. DenyUsers — warn if user is denied
	deny_users=$(printf '%s\n' "$sshd_full_config" |
		awk '/^denyusers / {$1=""; gsub(/^[[:space:]]+/,""); print; exit}' || true)
	if [[ -n "$deny_users" ]]; then
		if printf '%s' " ${deny_users} " | grep -q " ${REAL_USER} "; then
			warn "DenyUsers includes '$REAL_USER'. This user is denied SSH access."
		fi
	fi
fi

# --- 13. Port Conflict Check ---
port_holder=$(ss -Hltnp sport = :"${SSH_PORT}" 2>/dev/null || true)
if [[ -n "$port_holder" ]]; then
	if printf '%s\n' "$port_holder" | grep -qiE '(sshd|systemd)'; then
		info "Port $SSH_PORT is held by sshd/systemd (expected)."
	else
		warn "Port $SSH_PORT is in use by another process:"
		printf "  %s\n" "$port_holder" >&2
		warn "sshd may fail to start. Consider changing Port in sshd_config."
	fi
fi

# --- 14. Comprehensive Firewall Configuration ---

persist_iptables_rules() {
	local rules_dir="/etc/iptables"
	mkdir -p "$rules_dir" 2>/dev/null || true

	if command -v iptables-save &>/dev/null; then
		iptables-save >"${rules_dir}/iptables.rules" 2>/dev/null || true
	fi
	if command -v ip6tables-save &>/dev/null; then
		ip6tables-save >"${rules_dir}/ip6tables.rules" 2>/dev/null || true
	fi

	if rc-update add iptables default 2>/dev/null; then
		success "iptables rules saved and persistence enabled (OpenRC)."
	else
		warn "Could not enable iptables. Rules may not persist across reboots."
	fi
}

configure_firewalls() {
	local port="$1"
	local fw_count=0
	local has_ufw=false has_firewalld=false
	local has_raw_iptables=false has_raw_nft=false

	# ── Inventory active firewalls ──
	if command -v ufw &>/dev/null; then
		local ufw_status_out
		ufw_status_out=$(ufw status 2>/dev/null || true)
		if printf '%s\n' "$ufw_status_out" | grep -qi "Status: active"; then
			has_ufw=true
			((fw_count++)) || true
		fi
	fi

	if command -v firewall-cmd &>/dev/null &&
		systemctl is-active --quiet firewalld 2>/dev/null; then
		has_firewalld=true
		((fw_count++)) || true
	fi

	# Raw iptables — only relevant when no manager is running
	if [[ "$has_ufw" == "false" ]] && [[ "$has_firewalld" == "false" ]]; then
		if command -v iptables &>/dev/null; then
			local input_policy
			input_policy=$(iptables -S INPUT 2>/dev/null |
				awk '/^-P INPUT/ {print $3; exit}' || true)
			if [[ "$input_policy" == "DROP" ]] || [[ "$input_policy" == "REJECT" ]]; then
				has_raw_iptables=true
				((fw_count++)) || true
			fi
		fi

		# nftables standalone — only if iptables command is absent entirely
		# (if iptables exists, it may be iptables-nft which manages nft rules)
		if ! command -v iptables &>/dev/null && command -v nft &>/dev/null; then
			local nft_ruleset
			nft_ruleset=$(nft list ruleset 2>/dev/null || true)
			# FIXED: Scoped to input hook (Script 2 matched any chain's policy,
			# which could false-positive on forward/output chains with drop policy)
			if printf '%s\n' "$nft_ruleset" |
				grep -qiE 'hook[[:space:]]+input.*policy[[:space:]]+(drop|reject)'; then
				has_raw_nft=true
				((fw_count++)) || true
			fi
		fi
	fi

	# ── Warn if multiple managers are active ──
	if [[ "$has_ufw" == "true" ]] && [[ "$has_firewalld" == "true" ]]; then
		warn "Both UFW and firewalld are active. This is a misconfiguration."
		warn "Configuring both, but consider disabling one."
	fi

	# ── Handle UFW ──
	if [[ "$has_ufw" == "true" ]]; then
		info "Configuring UFW for SSH (port $port)..."
		local ufw_rules
		ufw_rules=$(ufw status 2>/dev/null || true)
		# Match: "22 ALLOW", "22/tcp ALLOW", "22 (v6) ALLOW"
		if printf '%s\n' "$ufw_rules" | grep -qE "^${port}[[:space:]/].*ALLOW"; then
			success "UFW already allows port $port."
		else
			if ufw allow "${port}/tcp" >/dev/null 2>&1; then
				success "UFW: allowed port ${port}/tcp."
			else
				warn "Failed to add UFW rule for port $port."
			fi
		fi
	fi

	# ── Handle firewalld ──
	if [[ "$has_firewalld" == "true" ]]; then
		info "Configuring firewalld for SSH (port $port)..."
		local default_zone
		default_zone=$(firewall-cmd --get-default-zone 2>/dev/null || echo "public")

		if [[ "$port" == "22" ]]; then
			# Standard port — use the built-in ssh service definition
			if firewall-cmd --zone="$default_zone" --query-service=ssh &>/dev/null; then
				success "firewalld already allows SSH service in '$default_zone'."
			else
				if firewall-cmd --permanent --zone="$default_zone" --add-service=ssh >/dev/null 2>&1 &&
					firewall-cmd --reload >/dev/null 2>&1; then
					success "firewalld: SSH service allowed in '$default_zone'."
				else
					warn "Failed to add SSH service in firewalld."
				fi
			fi
		else
			# Non-standard port — --add-service=ssh would open 22, not our port
			if firewall-cmd --zone="$default_zone" --query-port="${port}/tcp" &>/dev/null; then
				success "firewalld already allows port ${port}/tcp in '$default_zone'."
			else
				if firewall-cmd --permanent --zone="$default_zone" \
					--add-port="${port}/tcp" >/dev/null 2>&1 &&
					firewall-cmd --reload >/dev/null 2>&1; then
					success "firewalld: port ${port}/tcp allowed in '$default_zone'."
				else
					warn "Failed to add port $port in firewalld."
				fi
			fi
		fi
	fi

	# ── Handle raw iptables (no manager active) ──
	if [[ "$has_raw_iptables" == "true" ]]; then
		info "Configuring iptables for SSH (port $port)..."

		# IPv4
		if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null; then
			if iptables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
				success "iptables: ACCEPT rule added for port $port (IPv4)."
			else
				warn "Failed to add iptables IPv4 rule for port $port."
			fi
		else
			success "iptables already allows port $port (IPv4)."
		fi

		# IPv6 — only insert if policy is also restrictive
		if command -v ip6tables &>/dev/null; then
			local ip6_policy
			ip6_policy=$(ip6tables -S INPUT 2>/dev/null |
				awk '/^-P INPUT/ {print $3; exit}' || true)
			if [[ "$ip6_policy" == "DROP" ]] || [[ "$ip6_policy" == "REJECT" ]]; then
				if ! ip6tables -C INPUT -p tcp --dport "$port" -j ACCEPT &>/dev/null; then
					if ip6tables -I INPUT 1 -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
						success "ip6tables: ACCEPT rule added for port $port (IPv6)."
					else
						warn "Failed to add ip6tables IPv6 rule for port $port."
					fi
				else
					success "ip6tables already allows port $port (IPv6)."
				fi
			fi
		fi

		# Persist rules across reboots
		persist_iptables_rules
	fi

	# ── Handle raw nftables (no iptables interface) ──
	if [[ "$has_raw_nft" == "true" ]]; then
		warn "nftables has a blocking input policy but no iptables interface is available."
		warn "Please manually allow SSH. Example:"
		warn "  nft add rule inet filter input tcp dport $port accept"
		warn "(Adjust table/chain names to match your ruleset.)"
	fi

	# ── No firewall at all ──
	if [[ $fw_count -eq 0 ]]; then
		info "No active firewall detected. Port $port should be accessible."
	fi
}

configure_firewalls "$SSH_PORT"

# --- 15. Service Management ---

# Re-check for conflicts (state may have changed since section 10)
if [[ "$SSH_UNIT" == "sshd.service" ]]; then
	if systemctl is-active --quiet sshd.socket 2>/dev/null; then
		info "sshd.socket became active. Switching to socket activation."
		SSH_UNIT="sshd.socket"
		SSH_UNIT_TYPE="socket"
	fi
elif [[ "$SSH_UNIT" == "sshd.socket" ]]; then
	if systemctl is-active --quiet sshd.service 2>/dev/null; then
		info "sshd.service became active. Switching to service mode."
		SSH_UNIT="sshd.service"
		SSH_UNIT_TYPE="service"
	fi
fi

# Prevent boot-time conflict: stop AND disable the opposing unit
if [[ "$SSH_UNIT" == "sshd.service" ]]; then
	if rc-service sshd.socket status >/dev/null 2>&1; then
		info "Disabling sshd.socket to prevent conflict with sshd.service."
		rc-service sshd.socket stop 2>/dev/null || true
		rc-update del sshd.socket default 2>/dev/null || true
	fi
elif [[ "$SSH_UNIT" == "sshd.socket" ]]; then
	if rc-service sshd status >/dev/null 2>&1; then
		info "Disabling sshd.service to prevent conflict with sshd.socket."
		rc-service sshd stop 2>/dev/null || true
		rc-update del sshd default 2>/dev/null || true
	fi
fi

# Check if service is already active
_service_active=false
rc-service sshd status >/dev/null 2>&1 && _service_active=true

if $_service_active; then
	success "$SSH_UNIT is already active."
else
	info "Starting $SSH_UNIT..."

	rc-update add sshd default 2>/dev/null || true
	if ! rc-service sshd start >/dev/null 2>&1; then
		error "Failed to start sshd."
		die "Fix the issue and re-run."
	fi

	# Verify with brief retry
	sshd_attempts=0
	while [[ $sshd_attempts -lt 5 ]]; do
		_service_active=false
		rc-service sshd status >/dev/null 2>&1 && _service_active=true
		if $_service_active; then
			break
		fi
		((sshd_attempts++)) || true
		info "Waiting for $SSH_UNIT... ($sshd_attempts/5)"
		sleep 1
	done

	if rc-service sshd status >/dev/null 2>&1; then
		success "$SSH_UNIT is active."
	else
		error "$SSH_UNIT failed to stay active."
		systemctl status "$SSH_UNIT" --no-pager --lines=10 >&2 || true
		die "Check 'journalctl -xeu $SSH_UNIT' for details."
	fi
fi

# --- 16. Post-start Listening Verification ---
sleep 1
listen_check=$(ss -Hltnp sport = :"${SSH_PORT}" 2>/dev/null || true)
if [[ -n "$listen_check" ]]; then
	success "Verified: port $SSH_PORT is listening."
else
	warn "Port $SSH_PORT does not appear to be listening."
	warn "Check 'ss -tlnp' and 'journalctl -xeu $SSH_UNIT' for details."
fi

# --- 17. Tailscale Handling ---
USE_TAILSCALE_IP=false
TAILSCALE_IP=""

if command -v tailscale &>/dev/null &&
	systemctl is-active --quiet tailscaled 2>/dev/null; then
	TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || true)

	if [[ -n "$TAILSCALE_IP" ]]; then
		printf "\n%s[Tailscale Detected]%s\n" "$C_MAGENTA" "$C_RESET"
		printf "Tailscale IP: %s%s%s\n" "$C_BOLD" "$TAILSCALE_IP" "$C_RESET"

		if [[ "$AUTO_MODE" == "true" ]]; then
			ts_choice="Y"
		else
			if ! read -r -p "${C_YELLOW}Use Tailscale IP for remote connection? [y/N]${C_RESET} " ts_choice; then
				ts_choice="N"
			fi
			ts_choice=${ts_choice:-N}
		fi

		if [[ "$ts_choice" =~ ^[yY]([eE][sS])?$ ]]; then
			USE_TAILSCALE_IP=true

			# Trust Tailscale interface in firewalld (if active)
			# UFW/iptables already allow the SSH port on all interfaces — no extra step
			if command -v firewall-cmd &>/dev/null &&
				systemctl is-active --quiet firewalld 2>/dev/null; then
				ts_iface=$(ip -o link show 2>/dev/null |
					awk -F': ' '/tailscale/ {
                        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                        print $2; exit
                    }' || true)
				# MERGED: From Script 1 — strip "@NONE" suffix that ip -o produces
				# (e.g. "tailscale0@NONE" → "tailscale0"), which would otherwise
				# cause firewall-cmd --add-interface to fail silently.
				ts_iface=${ts_iface%@*}
				ts_iface=${ts_iface:-tailscale0}

				if ! firewall-cmd --zone=trusted \
					--query-interface="$ts_iface" &>/dev/null; then
					info "Trusting interface $ts_iface in firewalld..."
					if firewall-cmd --permanent --zone=trusted \
						--add-interface="$ts_iface" >/dev/null 2>&1 &&
						firewall-cmd --reload >/dev/null 2>&1; then
						success "Tailscale traffic is now trusted."
					else
						warn "Failed to trust Tailscale interface in firewalld."
					fi
				fi
			fi
		fi
	fi
fi

# --- 18. Smart IP Detection ---
TARGET_IP=""

if [[ "$USE_TAILSCALE_IP" == "true" ]]; then
	TARGET_IP="$TAILSCALE_IP"
else
	info "Detecting Local LAN IP..."

	# Priority 1: Physical Ethernet/WiFi (excluding virtual/tunnel interfaces)
	# Single awk — no cut|head pipeline, no SIGPIPE risk
	CANDIDATE_IP=$(ip -o -4 addr show scope global 2>/dev/null |
		awk '
            $2 ~ /^(e|w)/ &&
            $2 !~ /(docker|br-|vbox|virbr|waydroid|tun|warp|wg)/ {
                split($4, a, "/")
                print a[1]
                exit
            }
        ' || true)

	if [[ -n "$CANDIDATE_IP" ]]; then
		TARGET_IP="$CANDIDATE_IP"
	else
		# Fallback: interface carrying the default route
		DEFAULT_IFACE=$(ip route show default 2>/dev/null |
			awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)
		if [[ -n "$DEFAULT_IFACE" ]]; then
			TARGET_IP=$(ip -o -4 addr show scope global dev "$DEFAULT_IFACE" 2>/dev/null |
				awk '{split($4, a, "/"); print a[1]; exit}' || true)
		fi
	fi
fi

if [[ -z "$TARGET_IP" ]]; then
	TARGET_IP="<IP-NOT-FOUND>"
	warn "Could not determine IP address automatically."
fi

# --- 19. Final Output ---
if [[ "$SSH_PORT" == "22" ]]; then
	CONN_CMD="ssh ${REAL_USER}@${TARGET_IP}"
else
	CONN_CMD="ssh -p ${SSH_PORT} ${REAL_USER}@${TARGET_IP}"
fi

printf "\n%s======================================================%s\n" "$C_GREEN" "$C_RESET"
printf " %sSSH Setup Complete!%s\n" "$C_BOLD" "$C_RESET"
printf "%s======================================================%s\n" "$C_GREEN" "$C_RESET"
printf " %-15s : %s%s%s\n" "IP Address" "$C_CYAN" "$TARGET_IP" "$C_RESET"
printf " %-15s : %s%s%s\n" "Port" "$C_CYAN" "$SSH_PORT" "$C_RESET"
printf " %-15s : %s%s%s\n" "User" "$C_CYAN" "$REAL_USER" "$C_RESET"
if [[ "$SSH_UNIT_TYPE" == "socket" ]]; then
	printf " %-15s : %s%s%s\n" "Activation" "$C_CYAN" "socket (on-demand)" "$C_RESET"
fi
printf "\n Connect from another device:\n"
printf "    %s%s%s\n\n" "$C_MAGENTA" "$CONN_CMD" "$C_RESET"
printf "%s======================================================%s\n" "$C_GREEN" "$C_RESET"

if [[ -t 0 ]] && [[ "$AUTO_MODE" != "true" ]]; then
	read -r -p "Press ${C_BOLD}[Enter]${C_RESET} to close setup..." || true
fi

exit 0
