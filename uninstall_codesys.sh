#!/bin/bash
# ==============================================================================
# CODESYS - Uninstall script
# Version : 1.0
# Removes:
#   - CODESYS Virtual Control SL  (Docker container + image + VirtualControlAPI)
#   - CODESYS License Server SL   (.deb packages)
#   - CodeMeter Lite               (.deb package + files)
#
# Usage: sudo ./uninstall_codesys.sh [--vcontrol] [--licenseserver] [--codemeter] [--all]
# Without argument: removes everything (equivalent to --all)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors and log helpers
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_section() {
    echo -e "\n${CYAN}══════════════════════════════════════════${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}══════════════════════════════════════════${NC}"
}

die() { log_error "$*"; exit 1; }

# ------------------------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

usage() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --vcontrol      Remove Virtual Control SL (container, image, API script)"
    echo "  --licenseserver Remove License Server SL (.deb packages)"
    echo "  --codemeter     Remove CodeMeter Lite (.deb + files)"
    echo "  --all           Remove everything (default if no argument given)"
    echo "  --help          Show this help"
}

# ==============================================================================
# MODULE 1 — CODESYS VIRTUAL CONTROL SL
# ==============================================================================

uninstall_vcontrol() {
    log_section "MODULE — Virtual Control SL"

    local api="/root/VirtualControlAPI.py"
    local instance="vcontrol"
    local basedir="/var/opt/codesysvcontrol"

    # Stop and delete the instance via VirtualControlAPI if available
    if [[ -f "$api" ]]; then
        log_info "Stopping instance '$instance' ..."
        python3 "$api" --stop "$instance" 2>/dev/null || true

        log_info "Deleting instance '$instance' ..."
        python3 "$api" --delete "$instance" 2>/dev/null || true
    else
        log_warn "VirtualControlAPI.py not found — stopping container directly."
        docker stop "$instance" 2>/dev/null || true
        docker rm   "$instance" 2>/dev/null || true
    fi

    # Remove Docker images tagged codesyscontrol*
    log_info "Removing CODESYS Docker images ..."
    local images
    images=$(docker images --format '{{.Repository}}:{{.Tag}}' \
             | grep -i "codesyscontrol" || true)
    if [[ -n "$images" ]]; then
        echo "$images" | while read -r img; do
            docker rmi "$img" 2>/dev/null && log_ok "Removed image: $img" \
                || log_warn "Could not remove image: $img (may be in use)"
        done
    else
        log_warn "No CODESYS Docker images found."
    fi

    # Remove VirtualControlAPI systemd service
    log_info "Removing VirtualControlAPI systemd service ..."
    local svc="/lib/systemd/system/VirtualControlAPI.service"
    if [[ -f "$svc" ]]; then
        systemctl stop    VirtualControlAPI.service 2>/dev/null || true
        systemctl disable VirtualControlAPI.service 2>/dev/null || true
        rm -f "$svc"
        systemctl daemon-reload
        log_ok "VirtualControlAPI.service removed."
    else
        log_warn "VirtualControlAPI.service not found."
    fi

    # Remove VirtualControlAPI.py
    if [[ -f "$api" ]]; then
        rm -f "$api"
        log_ok "Removed $api"
    fi

    # Remove instance data directory
    if [[ -d "$basedir" ]]; then
        log_info "Removing $basedir ..."
        rm -rf "$basedir"
        log_ok "Removed $basedir"
    else
        log_warn "$basedir not found — already clean."
    fi

    log_ok "Virtual Control SL removed."
}

# ==============================================================================
# MODULE 2 — CODESYS LICENSE SERVER SL
# ==============================================================================

uninstall_licenseserver() {
    log_section "MODULE — License Server SL"

    local packages=("codesyswbmlicensing" "codesyswbmbase" "codesyslicenseserver")

    for pkg in "${packages[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii\|^iU\|^iF"; then
            log_info "Purging $pkg ..."
            dpkg --purge --force-all "$pkg" 2>/dev/null && log_ok "$pkg removed." \
                || log_warn "Could not purge $pkg cleanly."
        else
            log_warn "$pkg not installed — skipping."
        fi
    done

    log_ok "License Server SL removed."
}

# ==============================================================================
# MODULE 3 — CODEMETER LITE
# ==============================================================================

uninstall_codemeter() {
    log_section "MODULE — CodeMeter Lite"

    # Stop services first
    for svc in codemeter-webadmin codemeter; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            log_info "Stopping $svc ..."
            systemctl stop "$svc" 2>/dev/null || true
        fi
        systemctl disable "$svc" 2>/dev/null || true
    done

    # Remove via dpkg if registered
    for pkg in codemeter-lite codemeter; do
        if dpkg -l "$pkg" 2>/dev/null | grep -qE "^ii|^iU|^iF|^rc"; then
            log_info "Purging $pkg ..."
            dpkg --purge --force-all "$pkg" 2>/dev/null && log_ok "$pkg removed." \
                || log_warn "Could not purge $pkg cleanly."
        fi
    done

    # Remove residual files (from manual copy install)
    log_info "Removing CodeMeter residual files ..."
    rm -rf \
        /var/lib/CodeMeter \
        /var/log/CodeMeter \
        /etc/wibu \
        /usr/sbin/CodeMeterLin \
        /usr/sbin/CmWebAdmin \
        /usr/bin/cmu \
        /usr/bin/codemeter-info \
        /lib/systemd/system/codemeter.service \
        /lib/systemd/system/codemeter-webadmin.service \
        /usr/lib/systemd/system/codemeter.service \
        /usr/lib/systemd/system/codemeter-webadmin.service \
        /etc/systemd/system/multi-user.target.wants/codemeter.service \
        /etc/systemd/system/multi-user.target.wants/codemeter-webadmin.service \
        /etc/init.d/codemeter \
        /etc/init.d/codemeter-webadmin \
        /lib/udev/rules.d/60-codemeter-lite.rules \
        2>/dev/null || true

    # Remove shared libraries
    find /usr/lib -name "libwibucm*" -delete 2>/dev/null || true
    find /usr/lib -name "libwibucmJNI*" -delete 2>/dev/null || true

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    log_ok "CodeMeter Lite removed."
}

# ==============================================================================
# Final dpkg consistency check
# ==============================================================================

fix_dpkg() {
    log_section "Fixing dpkg state"
    dpkg --configure -a 2>/dev/null || true
    if command -v apt-get &>/dev/null; then
        apt-get install -f -y --no-install-recommends 2>/dev/null || true
    fi
    log_ok "dpkg state cleaned up."
}

# ==============================================================================
# Main
# ==============================================================================

main() {
    echo -e "${RED}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║           CODESYS — Uninstall                    ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local do_vc=false
    local do_ls=false
    local do_cm=false

    if [[ $# -eq 0 ]]; then
        do_vc=true; do_ls=true; do_cm=true
    else
        for arg in "$@"; do
            case "$arg" in
                --vcontrol)      do_vc=true ;;
                --licenseserver) do_ls=true ;;
                --codemeter)     do_cm=true ;;
                --all)           do_vc=true; do_ls=true; do_cm=true ;;
                --help|-h)       usage; exit 0 ;;
                *) die "Unknown argument: $arg  (use --help)" ;;
            esac
        done
    fi

    check_root

    $do_vc && uninstall_vcontrol
    $do_ls && uninstall_licenseserver
    $do_cm && uninstall_codemeter

    # Always fix dpkg state at the end
    fix_dpkg

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         Uninstall completed successfully  ✔       ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
}

main "$@"
