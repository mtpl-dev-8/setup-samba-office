#!/usr/bin/env bash
#
# setup-samba-office.sh
#
# Usage:
#   sudo ./setup-samba-office.sh            # prompts for usernames interactively
#   sudo ./setup-samba-office.sh alice bob  # add users alice and bob
#
# Notes:
#  - Run as root (sudo). Script is idempotent: safe to re-run.
#  - Assumes the directory to share is /srv/files (change MOUNT_POINT below if needed).
#  - It will prompt for smbpasswd for each user (this sets the Samba password).
#
set -euo pipefail

# --------- Configurable defaults ----------
MOUNT_POINT="/srv/files/devops"
GROUP="devops"
SHARE_NAME="Devops"
SMB_CONF="/etc/samba/smb.conf"
SMB_CONF_BACKUP_DIR="/etc/samba/backup-smbconf-$(date +%Y%m%d%H%M%S)"
GLOBAL_SNIPPET_MARKER="# === managed-by-setup-samba-office ==="
SHARE_SNIPPET_MARKER="# === managed-by-setup-samba-office:share ==="
# ------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: Please run as root (sudo)." >&2
  exit 2
fi

info(){ echo -e "\e[34m[INFO]\e[0m $*"; }
warn(){ echo -e "\e[33m[WARN]\e[0m $*"; }
err(){ echo -e "\e[31m[ERROR]\e[0m $*" >&2; }

# Helper to run commands shown
run(){ echo "+ $*"; "$@"; }

# Ensure mount point exists
if [[ ! -d "$MOUNT_POINT" ]]; then
  warn "$MOUNT_POINT does not exist. Creating it."
  run mkdir -p "$MOUNT_POINT"
fi

# Is it a mountpoint?
if ! mountpoint -q "$MOUNT_POINT"; then
  warn "$MOUNT_POINT is not a mount point currently. The share will still be created, but ensure the disk is mounted at $MOUNT_POINT for persistence."
else
  info "$MOUNT_POINT is mounted."
fi

# Install samba if not installed
if ! command -v smbd >/dev/null 2>&1; then
  info "Samba not found — installing package(s)..."
  if command -v apt-get >/dev/null 2>&1; then
    run apt-get update
    run apt-get install -y samba samba-common-bin
  elif command -v yum >/dev/null 2>&1; then
    run yum install -y samba samba-client
  else
    err "Package manager not recognized. Install Samba manually and re-run the script."
    exit 3
  fi
else
  info "Samba appears installed."
fi

# Create group if missing
if ! getent group "$GROUP" >/dev/null; then
  info "Creating group '$GROUP'"
  run groupadd "$GROUP"
else
  info "Group '$GROUP' already exists."
fi

# Ensure ownership and permissions
info "Setting ownership and permissions on $MOUNT_POINT -> root:$GROUP and 2770"
run chown -R root:"$GROUP" "$MOUNT_POINT"
run chmod -R 2770 "$MOUNT_POINT"

# Backup smb.conf (and folder if present)
info "Backing up existing Samba configuration to $SMB_CONF_BACKUP_DIR"
run mkdir -p "$SMB_CONF_BACKUP_DIR"
if [[ -f "$SMB_CONF" ]]; then
  run cp -a "$SMB_CONF" "$SMB_CONF_BACKUP_DIR/smb.conf"
fi
if [[ -d /etc/samba ]]; then
  # copy other files in /etc/samba (non-recursive, to preserve)
  run cp -a /etc/samba/* "$SMB_CONF_BACKUP_DIR/" 2>/dev/null || true
fi

# Detect LAN interface and network CIDR to restrict interfaces
# Use ip route to 8.8.8.8 to find source IP and interface
LAN_IF=""
LAN_CIDR=""
if ip -4 route get 8.8.8.8 >/dev/null 2>&1; then
  # get interface and source IP
  read -r _ _ _ src _ dev _ < <(ip -4 route get 8.8.8.8 2>/dev/null | awk '{print $1,$2,$3,$4,$5,$6,$7}')
  # fallback parsing if above didn't provide
  if [[ -z "$dev" ]]; then
    dev=$(ip -4 route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
  fi
  if [[ -n "$dev" ]]; then
    LAN_IF="$dev"
    # find the CIDR of that interface (first IPv4 address)
    LAN_CIDR=$(ip -4 -o addr show dev "$LAN_IF" | awk '{print $4}' | head -n1 || true)
  fi
fi
if [[ -z "$LAN_IF" || -z "$LAN_CIDR" ]]; then
  warn "Unable to reliably detect LAN interface/network. Samba will not restrict interfaces automatically."
  INTERFACES_LINE=""
else
  info "Detected LAN interface: $LAN_IF, network: $LAN_CIDR"
  INTERFACES_LINE="interfaces = ${LAN_CIDR} lo"
fi

# Write global snippet if not already present
if grep -Fq "$GLOBAL_SNIPPET_MARKER" "$SMB_CONF" 2>/dev/null || grep -Fq "$GLOBAL_SNIPPET_MARKER" "$SMB_CONF_BACKUP_DIR/smb.conf" 2>/dev/null; then
  info "Global Samba snippet already present in $SMB_CONF (managed by this script). Skipping global insert."
else
  info "Adding secure global Samba snippet to $SMB_CONF"
  cat >> "$SMB_CONF" <<EOF

$GLOBAL_SNIPPET_MARKER
[global]
   server string = Office File Server
   workgroup = WORKGROUP
   netbios name = $(hostname -s)
   # Restrict to local LAN interface(s) where possible
EOF

  if [[ -n "$INTERFACES_LINE" ]]; then
    cat >> "$SMB_CONF" <<EOF
   $INTERFACES_LINE
   bind interfaces only = yes
EOF
  fi

  cat >> "$SMB_CONF" <<'EOF'
   # Security / performance
   client max protocol = SMB3
   server min protocol = SMB2
   smb encrypt = desired
   obey pam restrictions = yes
   log file = /var/log/samba/log.%m
   max log size = 1000
   # Reduce guest access by default
   map to guest = Never
# === end managed-by-setup-samba-office ===
EOF
fi

# Append the share configuration if not present
if grep -Fq "$SHARE_SNIPPET_MARKER" "$SMB_CONF"; then
  info "Share $SHARE_NAME already configured in $SMB_CONF (managed by this script). Skipping share insert."
else
  info "Adding share [$SHARE_NAME] pointing to $MOUNT_POINT in $SMB_CONF"
  cat >> "$SMB_CONF" <<EOF

$SHARE_SNIPPET_MARKER
[$SHARE_NAME]
   path = $MOUNT_POINT
   browseable = yes
   read only = no
   writable = yes
   valid users = @${GROUP}
   force group = ${GROUP}
   create mask = 0660
   directory mask = 2770
   guest ok = no
# === end managed-by-setup-samba-office:share ===
EOF
fi

# Reload systemd mounts (if hint present earlier) and restart samba services
info "Reloading systemd daemon and restarting Samba services"
run systemctl daemon-reload || true
run systemctl restart smbd nmbd >/dev/null 2>&1 || run systemctl restart smbd >/dev/null 2>&1 || true

# Function to create/add users
add_user_samba() {
  local user="$1"

  if id -u "$user" >/dev/null 2>&1; then
    info "System user '$user' already exists."
  else
    info "Creating system user '$user' (no password)."
    # create without home (-M), no-login shell /usr/sbin/nologin to avoid interactive shell
    run useradd -M -s /usr/sbin/nologin "$user" || {
      warn "useradd failed for $user — you may need to create the user manually."
    }
  fi

  # Add to group
  if id -nG "$user" | grep -qw "$GROUP"; then
    info "User '$user' is already in group '$GROUP'."
  else
    info "Adding user '$user' to group '$GROUP'."
    run usermod -aG "$GROUP" "$user"
  fi

  # Samba password: use smbpasswd (interactive). If user already a Samba user, smbpasswd -a will prompt to set/change.
  info "Now set a Samba password for user '$user' (this will prompt)."
  run smbpasswd -a "$user" || {
    warn "smbpasswd failed for $user. You may need to run 'sudo smbpasswd -a $user' manually."
  }
  # enable the smb user
  run smbpasswd -e "$user" || true
}

# Collect usernames: either from CLI args or prompt
USERNAMES=()
if [[ $# -gt 0 ]]; then
  # positional args are usernames
  for u in "$@"; do
    USERNAMES+=("$u")
  done
else
  # interactive prompt
  echo
  read -r -p "Enter usernames to add (space-separated), or press ENTER to skip creating users now: " LINE
  if [[ -n "$LINE" ]]; then
    # split into array
    read -r -a USERNAMES <<< "$LINE"
  fi
fi

# Process each user
if [[ ${#USERNAMES[@]} -eq 0 ]]; then
  info "No users provided. Skipping user creation step."
else
  for u in "${USERNAMES[@]}"; do
    add_user_samba "$u"
  done
fi

# Final reload / restart to ensure config applied
info "Final restart of Samba to apply configuration"
run systemctl restart smbd nmbd >/dev/null 2>&1 || run systemctl restart smbd >/dev/null 2>&1 || true

# Output connection info
echo
info "Samba share setup complete."
echo "Share name: $SHARE_NAME"
echo "Path: ${MOUNT_POINT}"
echo
# find primary IPv4 address for user convenience
PRIMARY_IP=$(ip -4 addr show scope global | awk '/inet/ && !/127.0.0.1/ {print $2; exit}' | cut -d/ -f1 || true)
if [[ -n "$PRIMARY_IP" ]]; then
  echo "Clients can connect using:"
  echo "  Windows:   \\\\${PRIMARY_IP}\\${SHARE_NAME}"
  echo "  macOS:     smb://${PRIMARY_IP}/${SHARE_NAME}"
  echo "  Linux:     smb://<server-ip>/${SHARE_NAME}  or mount -t cifs //${PRIMARY_IP}/${SHARE_NAME} ..."
else
  echo "Clients can connect to: \\\\\\SERVER_IP\\${SHARE_NAME}  (replace SERVER_IP with the server's IP address)"
fi

echo
info "Notes & next steps:"
echo " - Ensure the server has a fixed IP (DHCP reservation) or use hostname if DNS/resolution available."
echo " - Add additional Linux users and 'sudo smbpasswd -a username' to create Samba access for them."
echo " - If any client fails to connect, check firewall (ports 445/tcp and 139/tcp) and Samba logs: /var/log/samba/"
echo " - To remove this share later: edit $SMB_CONF and remove the block between the markers:"
echo "     $SHARE_SNIPPET_MARKER  ...  # === end managed-by-setup-samba-office:share ==="
echo
info "Done."

