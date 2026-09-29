#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_NAME="$(basename "$0")"

readonly LOG_FILE="/var/log/kijani-provision.log"

log() {

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"

}

phase() {

    echo

    log "=================================================="

    log "$1"

    log "=================================================="

}

trap 'log "ERROR: Provisioning failed at line $LINENO."' ERR

# ==========================================================

# PHASE 1 — PRE-FLIGHT VALIDATION

# ==========================================================

phase "PHASE 1/8 — Pre-flight validation"

if [[ "${EUID}" -ne 0 ]]; then

    echo "ERROR: Run this script with sudo."

    exit 1

fi

log "Running as root."

log "Script: ${SCRIPT_NAME}"

log "Hostname: $(hostname)"

log "Operating system: $(. /etc/os-release && echo "$PRETTY_NAME")"

# ==========================================================

# PHASE 2 — USERS AND GROUPS

# ==========================================================

phase "PHASE 2/8 — Users and groups"

REQUIRED_GROUPS=(

    "kijani-api"

    "kijani-payments"

    "kijani-worker"

)

for group_name in "${REQUIRED_GROUPS[@]}"; do

    if getent group "$group_name" >/dev/null 2>&1; then

        log "Group already exists: $group_name"

    else

        groupadd --system "$group_name"

        log "Created group: $group_name"

    fi

done

declare -A SERVICE_USERS=(

    ["kijani-api"]="kijani-api"

    ["kijani-payments"]="kijani-payments"

    ["kijani-worker"]="kijani-worker"

)

for user_name in "${!SERVICE_USERS[@]}"; do

    group_name="${SERVICE_USERS[$user_name]}"

    if id "$user_name" >/dev/null 2>&1; then

        log "Service account already exists: $user_name"

        current_shell="$(getent passwd "$user_name" | cut -d: -f7)"

        if [[ "$current_shell" != "/usr/sbin/nologin" ]]; then

            usermod --shell /usr/sbin/nologin "$user_name"

            log "Corrected shell for: $user_name"

        fi

        current_group="$(id -gn "$user_name")"

        if [[ "$current_group" != "$group_name" ]]; then

            usermod --gid "$group_name" "$user_name"

            log "Corrected primary group for: $user_name"

        fi

    else

        useradd \
            --system \
            --gid "$group_name" \
            --shell /usr/sbin/nologin \
            --no-create-home \
            "$user_name"

        log "Created service account: $user_name"

    fi

done

# ==========================================================

# PHASE 3 — DIRECTORIES AND PERMISSIONS

# ==========================================================

phase "PHASE 3/8 — Directories and permissions"

install -d \
    -o root \
    -g root \
    -m 0755 \
    /opt/kijani

install -d \
    -o kijani-api \
    -g kijani-api \
    -m 0750 \
    /opt/kijani/api

install -d \
    -o kijani-payments \
    -g kijani-payments \
    -m 0750 \
    /opt/kijani/payments

install -d \
    -o kijani-worker \
    -g kijani-worker \
    -m 0750 \
    /opt/kijani/worker

install -d \
    -o root \
    -g kijani-payments \
    -m 0750 \
    /etc/kijani

log "Application directories verified."

log "Directory ownership and permissions enforced."

# ==========================================================

# PHASE 4 — PACKAGES AND CONFIGURATION

# ==========================================================

phase "PHASE 4/8 — Packages and configuration"

REQUIRED_PACKAGES=(

    curl

    jq

    acl

    ufw

    logrotate

)

log "Updating APT package index."

apt-get update -y

for package_name in "${REQUIRED_PACKAGES[@]}"; do

    if dpkg -s "$package_name" >/dev/null 2>&1; then

        log "Package already installed: $package_name"

    else

        log "Installing package: $package_name"

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y "$package_name"

    fi

done

log "Configuring /etc/kijani/kijani.conf."

cat > /etc/kijani/kijani.conf <<'EOF'

ENV=production

DEBUG=false

API_PORT=8080

PAYMENTS_DEBUG=false

EOF

chown root:kijani-payments /etc/kijani/kijani.conf

chmod 0640 /etc/kijani/kijani.conf

log "Production configuration applied."

# ==========================================================

# PHASE 5 — SYSTEMD SERVICES AND HARDENING

# ==========================================================

phase "PHASE 5/8 — systemd services and hardening"

# Placeholder workload:

# Application binaries have not yet been deployed, so sleep infinity

# represents the long-running application process.

create_service() {

    local service_name="$1"

    local service_user="$2"

    local working_directory="$3"

    log "Configuring ${service_name}.service."

    cat > "/etc/systemd/system/${service_name}.service" <<EOF

[Unit]

Description=Kijani ${service_name} Service

After=network.target

[Service]

Type=simple

User=${service_user}

Group=${service_user}

WorkingDirectory=${working_directory}

ExecStart=/bin/sleep infinity

Restart=on-failure

RestartSec=5

NoNewPrivileges=true

PrivateTmp=true

PrivateDevices=true

ProtectSystem=strict

ProtectHome=true

ProtectKernelTunables=true

ProtectKernelModules=true

ProtectControlGroups=true

RestrictSUIDSGID=true

LockPersonality=true

[Install]

WantedBy=multi-user.target

EOF

    chmod 0644 "/etc/systemd/system/${service_name}.service"

}

create_service \
    "kijani-api" \
    "kijani-api" \
    "/opt/kijani/api"

create_service \
    "kijani-payments" \
    "kijani-payments" \
    "/opt/kijani/payments"

create_service \
    "kijani-worker" \
    "kijani-worker" \
    "/opt/kijani/worker"

log "Reloading systemd configuration."

systemctl daemon-reload

for service_name in \
    kijani-api \
    kijani-payments \
    kijani-worker

do

    systemctl enable "${service_name}.service"

    systemctl restart "${service_name}.service"

    log "Enabled and started ${service_name}.service."

done

# ==========================================================

# PHASE 6 — FIREWALL

# ==========================================================

phase "PHASE 6/8 — Firewall"

log "Configuring UFW firewall."

ufw default deny incoming

ufw default allow outgoing

# Preserve SSH access before enabling firewall.

ufw allow OpenSSH

# Remove old unrestricted 8080 rule if it exists.

ufw --force delete allow 8080/tcp >/dev/null 2>&1 || true

# Do NOT expose port 8080 publicly.

# The Kijani API placeholder currently does not listen on 8080.

ufw --force enable

log "UFW firewall configured and enabled."

# ==========================================================

# PHASE 7 — LOGGING AND MONITORING

# ==========================================================

phase "PHASE 7/8 — Logging and monitoring"

# ----------------------------------------------------------

# Persistent systemd journal

# ----------------------------------------------------------

log "Configuring persistent systemd journal."

install -d \
    -o root \
    -g systemd-journal \
    -m 2755 \
    /var/log/journal

install -d \
    -o root \
    -g root \
    -m 0755 \
    /etc/systemd/journald.conf.d

cat > /etc/systemd/journald.conf.d/kijani.conf <<'EOF'

[Journal]

Storage=persistent

SystemMaxUse=500M

RuntimeMaxUse=100M

MaxRetentionSec=14day

Compress=yes

EOF

systemctl restart systemd-journald

log "Persistent systemd journal configured."

# ----------------------------------------------------------

# Provisioning log rotation

# ----------------------------------------------------------

log "Configuring logrotate for Kijani provisioning logs."

cat > /etc/logrotate.d/kijani-provision <<'EOF'

/var/log/kijani-provision.log {

    weekly

    rotate 8

    compress

    delaycompress

    missingok

    notifempty

    create 0640 root adm

}

EOF

chmod 0644 /etc/logrotate.d/kijani-provision

log "Log rotation configured."

# ----------------------------------------------------------

# Kijani health monitoring

# ----------------------------------------------------------

log "Installing Kijani health-check script."

cat > /usr/local/bin/kijani-healthcheck <<'EOF'

#!/usr/bin/env bash

set -u

FAILED=0

echo "=============================================="

echo "KIJANI HEALTH CHECK"

echo "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"

echo "Hostname: $(hostname)"

echo "=============================================="

echo

echo "SERVICES"

echo "----------------------------------------------"

for service in \
    kijani-api \
    kijani-payments \
    kijani-worker

do

    if systemctl is-active --quiet "${service}.service"; then

        echo "[OK] ${service}.service is active"

    else

        echo "[FAIL] ${service}.service is not active"

        FAILED=1

    fi

done

echo

echo "FIREWALL"

echo "----------------------------------------------"

if ufw status | grep -q "^Status: active"; then

    echo "[OK] UFW is active"

else

    echo "[FAIL] UFW is not active"

    FAILED=1

fi

echo

echo "CONFIGURATION"

echo "----------------------------------------------"

if [[ -f /etc/kijani/kijani.conf ]]; then

    echo "[OK] /etc/kijani/kijani.conf exists"

else

    echo "[FAIL] /etc/kijani/kijani.conf missing"

    FAILED=1

fi

echo

echo "DIRECTORIES"

echo "----------------------------------------------"

for directory in \
    /opt/kijani/api \
    /opt/kijani/payments \
    /opt/kijani/worker

do

    if [[ -d "$directory" ]]; then

        echo "[OK] $directory exists"

    else

        echo "[FAIL] $directory missing"

        FAILED=1

    fi

done

echo

echo "=============================================="

if [[ "$FAILED" -eq 0 ]]; then

    echo "OVERALL STATUS: HEALTHY"

else

    echo "OVERALL STATUS: FAILED"

fi

echo "=============================================="

exit "$FAILED"

EOF

chown root:root /usr/local/bin/kijani-healthcheck

chmod 0755 /usr/local/bin/kijani-healthcheck

log "Kijani health-check installed."

# ----------------------------------------------------------

# systemd health-check service

# ----------------------------------------------------------

log "Installing Kijani health-check systemd service."

cat > /etc/systemd/system/kijani-healthcheck.service <<'EOF'

[Unit]

Description=Kijani Platform Health Check

After=kijani-api.service kijani-payments.service kijani-worker.service

[Service]

Type=oneshot

ExecStart=/usr/local/bin/kijani-healthcheck

User=root

Group=root

NoNewPrivileges=true

PrivateTmp=true

ProtectHome=true

[Install]

WantedBy=multi-user.target

EOF

chmod 0644 /etc/systemd/system/kijani-healthcheck.service

# ----------------------------------------------------------

# systemd health-check timer

# ----------------------------------------------------------

log "Installing Kijani health-check timer."

cat > /etc/systemd/system/kijani-healthcheck.timer <<'EOF'

[Unit]

Description=Run Kijani Platform Health Check

[Timer]

OnBootSec=2min

OnUnitActiveSec=5min

Persistent=true

[Install]

WantedBy=timers.target

EOF

chmod 0644 /etc/systemd/system/kijani-healthcheck.timer

systemctl daemon-reload

systemctl enable --now kijani-healthcheck.timer

log "Kijani health monitoring enabled."

# ==========================================================

# PHASE 8 — VERIFICATION

# ==========================================================

phase "PHASE 8/8 — Verification"

FAILED=0

verify_ok() {

    log "[PASS] $1"

}

verify_fail() {

    log "[FAIL] $1"

    FAILED=1

}

# ----------------------------------------------------------

# Verify users

# ----------------------------------------------------------

log "Verifying service accounts."

for user_name in \
    kijani-api \
    kijani-payments \
    kijani-worker

do

    if id "$user_name" >/dev/null 2>&1; then

        verify_ok "User exists: $user_name"

    else

        verify_fail "User missing: $user_name"

    fi

    shell="$(getent passwd "$user_name" | cut -d: -f7 || true)"

    if [[ "$shell" == "/usr/sbin/nologin" ]]; then

        verify_ok "$user_name uses /usr/sbin/nologin"

    else

        verify_fail "$user_name has incorrect shell: $shell"

    fi

done

# ----------------------------------------------------------

# Verify directories

# ----------------------------------------------------------

log "Verifying application directories."

declare -A EXPECTED_DIRS=(

    ["/opt/kijani"]="root:root:755"

    ["/opt/kijani/api"]="kijani-api:kijani-api:750"

    ["/opt/kijani/payments"]="kijani-payments:kijani-payments:750"

    ["/opt/kijani/worker"]="kijani-worker:kijani-worker:750"

)

for directory in "${!EXPECTED_DIRS[@]}"; do

    expected="${EXPECTED_DIRS[$directory]}"

    actual="$(stat -c '%U:%G:%a' "$directory" 2>/dev/null || true)"

    if [[ "$actual" == "$expected" ]]; then

        verify_ok "$directory -> $actual"

    else

        verify_fail "$directory expected $expected but found $actual"

    fi

done

# ----------------------------------------------------------

# Verify configuration

# ----------------------------------------------------------

log "Verifying production configuration."

if [[ -f /etc/kijani/kijani.conf ]]; then

    verify_ok "Configuration file exists."

    actual_config_permissions="$(

        stat -c '%U:%G:%a' /etc/kijani/kijani.conf

    )"

    if [[ "$actual_config_permissions" == \
          "root:kijani-payments:640" ]]; then

        verify_ok \
            "Configuration permissions are root:kijani-payments:640"

    else

        verify_fail \
            "Unexpected configuration permissions: ${actual_config_permissions}"

    fi

    if grep -qx 'ENV=production' /etc/kijani/kijani.conf &&

       grep -qx 'DEBUG=false' /etc/kijani/kijani.conf &&

       grep -qx 'API_PORT=8080' /etc/kijani/kijani.conf &&

       grep -qx 'PAYMENTS_DEBUG=false' /etc/kijani/kijani.conf; then

        verify_ok "Production configuration values verified."

    else

        verify_fail "Production configuration values are incorrect."

    fi

else

    verify_fail "Configuration file missing."

fi

# ----------------------------------------------------------

# Verify systemd services

# ----------------------------------------------------------

log "Verifying Kijani services."

for service_name in \
    kijani-api \
    kijani-payments \
    kijani-worker

do

    if systemctl is-enabled --quiet "${service_name}.service"; then

        verify_ok "${service_name}.service is enabled"

    else

        verify_fail "${service_name}.service is not enabled"

    fi

    if systemctl is-active --quiet "${service_name}.service"; then

        verify_ok "${service_name}.service is active"

    else

        verify_fail "${service_name}.service is not active"

    fi

done

# ----------------------------------------------------------

# Verify firewall

# ----------------------------------------------------------

log "Verifying firewall."

if ufw status | grep -q "^Status: active"; then

    verify_ok "UFW is active."

else

    verify_fail "UFW is not active."

fi

if ufw status | grep -qE '^OpenSSH[[:space:]]+ALLOW'; then

    verify_ok "SSH firewall access is allowed."

else

    verify_fail "SSH firewall rule is missing."

fi

if ufw status | grep -qE '^8080/tcp[[:space:]]+ALLOW'; then

    verify_fail "Port 8080 is unexpectedly exposed."

else

    verify_ok "Port 8080 is not publicly exposed."

fi

# ----------------------------------------------------------

# Verify persistent journal

# ----------------------------------------------------------

log "Verifying persistent journal."

if grep -qx 'Storage=persistent' \
    /etc/systemd/journald.conf.d/kijani.conf; then

    verify_ok "Persistent journal configured."

else

    verify_fail "Persistent journal configuration missing."

fi

if [[ -d /var/log/journal ]]; then

    verify_ok "/var/log/journal exists."

else

    verify_fail "/var/log/journal missing."

fi

# ----------------------------------------------------------

# Verify logrotate

# ----------------------------------------------------------

log "Verifying logrotate configuration."

if logrotate -d /etc/logrotate.conf >/dev/null 2>&1; then

    verify_ok "Logrotate configuration valid."

else

    verify_fail "Logrotate configuration invalid."

fi

# ----------------------------------------------------------

# Verify health monitoring

# ----------------------------------------------------------

log "Verifying health monitoring."

if [[ -x /usr/local/bin/kijani-healthcheck ]]; then

    verify_ok "Health-check executable installed."

else

    verify_fail "Health-check executable missing."

fi

if systemctl is-enabled --quiet kijani-healthcheck.timer; then

    verify_ok "Health-check timer enabled."

else

    verify_fail "Health-check timer not enabled."

fi

if systemctl is-active --quiet kijani-healthcheck.timer; then

    verify_ok "Health-check timer active."

else

    verify_fail "Health-check timer not active."

fi

# Run final application health check

if /usr/local/bin/kijani-healthcheck; then

    verify_ok "Kijani health check passed."

else

    verify_fail "Kijani health check failed."

fi

# ----------------------------------------------------------

# Final result

# ----------------------------------------------------------

echo

log "=================================================="

if [[ "$FAILED" -eq 0 ]]; then

    log "FINAL STATUS: ALL VERIFICATION CHECKS PASSED"

    log "Provisioning completed successfully."

    log "=================================================="

    exit 0

else

    log "FINAL STATUS: ONE OR MORE VERIFICATION CHECKS FAILED"

    log "=================================================="

    exit 1

fi