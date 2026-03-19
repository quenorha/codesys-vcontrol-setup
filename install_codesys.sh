#!/bin/bash
# ==============================================================================
# CODESYS - Script d'installation automatisé
# Version : 1.1
# Installs:
#   1. CODESYS License Server for Linux SL  (.package → .deb)
#   2. CODESYS Virtual Control SL           (.package → Docker + VirtualControlAPI)
#
# Usage: sudo ./install_codesys.sh
#        (both .package files must be in the same folder as this script)
#        VirtualControlAPI.py is extracted from the Virtual Control package
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# License Server component installation order (codemeter is a prerequisite, fetched separately)
LS_DEB_ORDER=("licenseserver" "wbmbase" "wbmlicensing")


# Virtual Control / VirtualControlAPI constants
VCONTROL_BASEDIR="/root"
VCONTROL_API_DEST="${VCONTROL_BASEDIR}/VirtualControlAPI.py"
INSTANCE_NAME="vcontrol"

# Global variables filled at runtime
LS_PACKAGE_FILE=""
LS_PACKAGE_VERSION=""
LS_WORK_DIR=""

VC_PACKAGE_FILE=""
VC_PACKAGE_VERSION=""
VC_WORK_DIR=""
ARCH_DIR=""
DELIVERY_DIR=""
DOCKER_IMAGE_NAME=""

# ------------------------------------------------------------------------------
# Common prerequisites
# ------------------------------------------------------------------------------
check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."
}

check_dependencies() {
    local missing=()
    for cmd in python3 docker dpkg; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] \
        || die "Missing dependencies: ${missing[*]}. Please install them before retrying."
    python3 -c "import zipfile" 2>/dev/null \
        || die "Python module 'zipfile' not found (incomplete python3 installation?)."
    log_ok "Dependencies found (python3, docker, dpkg)."
}

# ------------------------------------------------------------------------------
# Helper: extract a .package (zip) into a temporary directory
# ------------------------------------------------------------------------------
extract_package() {
    local package_file="$1"
    local work_dir
    work_dir=$(mktemp -d /tmp/codesys_install_XXXXXX)

    # Log to stderr so that stdout only contains the work_dir path,
    # allowing callers to capture it with $()
    echo -e "${CYAN}[INFO]${NC}  Extracting '$(basename "$package_file")' into $work_dir ..." >&2
    python3 -c "import zipfile, sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
        "$package_file" "$work_dir" \
        || { echo -e "${RED}[ERROR]${NC} Failed to extract $(basename "$package_file")." >&2; exit 1; }

    echo "$work_dir"
}

# ------------------------------------------------------------------------------
# Architecture detection (for Virtual Control)
# ------------------------------------------------------------------------------
detect_arch() {
    local raw_arch
    raw_arch=$(uname -m)
    case "$raw_arch" in
        x86_64)        ARCH_DIR="virtuallinux" ;;
        armv7l|armv6l) ARCH_DIR="virtuallinuxarm" ;;
        aarch64|arm64) ARCH_DIR="virtuallinuxarm64" ;;
        *) die "Unsupported architecture: $raw_arch" ;;
    esac
    log_ok "Detected architecture: $raw_arch  →  $ARCH_DIR"
}

# ------------------------------------------------------------------------------
# Cleanup on exit
# ------------------------------------------------------------------------------
cleanup() {
    for dir in "${LS_WORK_DIR:-}" "${VC_WORK_DIR:-}"; do
        [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir" && \
            log_info "Cleanup: removed $dir."
    done
}

# ==============================================================================
# MODULE 1 — CODESYS LICENSE SERVER
# ==============================================================================

ls_find_package() {
    local packages=()
    while IFS= read -r -d '' f; do
        basename "$f" | grep -qi "license" && packages+=("$f") || true
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.package" -print0)

    case ${#packages[@]} in
        0) die "No License Server .package file found in $SCRIPT_DIR" ;;
        1) LS_PACKAGE_FILE="${packages[0]}" ;;
        *)
            log_warn "Multiple License Server .package files detected:"
            for f in "${packages[@]}"; do log_warn "  $(basename "$f")"; done
            die "Place a single License Server .package file in the script folder."
            ;;
    esac

    LS_PACKAGE_VERSION=$(basename "$LS_PACKAGE_FILE" | grep -oP '\d+\.\d+\.\d+\.\d+' || echo "unknown")
    log_ok "Package  : $(basename "$LS_PACKAGE_FILE")"
    log_ok "Version  : $LS_PACKAGE_VERSION"
}

ls_install_codemeter() {
    # codemeter-lite_<version>_<arch>.deb must be placed alongside this script.

    if dpkg -l codemeter 2>/dev/null | grep -q "^ii" || dpkg -l codemeter-lite 2>/dev/null | grep -q "^ii"; then
        log_ok "CodeMeter already installed — skipping."
        return 0
    fi

    local cm_deb
    cm_deb=$(find "$SCRIPT_DIR" -maxdepth 1 -name "codemeter-lite_*.deb" -o -name "codemeter_*.deb" | head -n 1)
    [[ -n "$cm_deb" ]]         || die "No codemeter*.deb found in $SCRIPT_DIR\nPlace codemeter-lite_<version>_<arch>.deb alongside this script."

    log_info "Found: $(basename "$cm_deb")"
    log_info "Installing codemeter-lite via dpkg ..."
    dpkg -i "$cm_deb" || die "codemeter-lite installation failed."
    log_ok "CodeMeter installed and service started."
}

ls_install_debs() {
    local delivery_dir="$LS_WORK_DIR/Delivery"
    [[ -d "$delivery_dir" ]] || die "Delivery folder not found in the License Server package."

    # CodeMeter must be present before codesyslicenseserver
    log_section "  3a/3 — CodeMeter runtime (prerequisite)"
    ls_install_codemeter

    log_info "Installing License Server packages in order: ${LS_DEB_ORDER[*]}"

    for component in "${LS_DEB_ORDER[@]}"; do
        local component_dir="$delivery_dir/$component"
        [[ -d "$component_dir" ]] || die "Component folder not found: $component_dir"

        local deb_file
        deb_file=$(find "$component_dir" -maxdepth 1 -name "*.deb" | head -n 1)
        [[ -n "$deb_file" ]] || die "No .deb file found in $component_dir"

        log_info "[$component] → $(basename "$deb_file")"
        dpkg -i "$deb_file" || die "Failed to install $component. Check the output above."
        log_ok "[$component] installed."
    done
}

ls_check_service() {
    local svc="codesyslicenseserver"
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log_ok "Service '$svc' is active."
    elif systemctl list-unit-files --quiet "${svc}.service" &>/dev/null; then
        log_warn "Service '$svc' found but inactive — starting ..."
        systemctl enable --now "$svc" || log_warn "Unable to start $svc."
    else
        log_warn "Service '$svc' not detected (normally registered by the .deb packages)."
    fi
}

install_licenseserver() {
    log_section "MODULE 1/2 — CODESYS License Server SL"

    log_section "  1/3 — Package detection"
    ls_find_package

    log_section "  2/3 — Extraction"
    LS_WORK_DIR=$(extract_package "$LS_PACKAGE_FILE")

    log_section "  3/3 — .deb package installation"
    ls_install_debs
    ls_check_service

    log_ok "License Server $LS_PACKAGE_VERSION installed."
}

# ==============================================================================
# MODULE 2 — CODESYS VIRTUAL CONTROL SL
# ==============================================================================

vc_find_package() {
    local packages=()
    while IFS= read -r -d '' f; do
        basename "$f" | grep -qi "virtual" && packages+=("$f") || true
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -name "*.package" -print0)

    case ${#packages[@]} in
        0) die "No Virtual Control .package file found in $SCRIPT_DIR" ;;
        1) VC_PACKAGE_FILE="${packages[0]}" ;;
        *)
            log_warn "Multiple Virtual Control .package files detected:"
            for f in "${packages[@]}"; do log_warn "  $(basename "$f")"; done
            die "Place a single Virtual Control .package file in the script folder."
            ;;
    esac

    VC_PACKAGE_VERSION=$(basename "$VC_PACKAGE_FILE" | grep -oP '\d+\.\d+\.\d+\.\d+' || echo "unknown")
    log_ok "Package  : $(basename "$VC_PACKAGE_FILE")"
    log_ok "Version  : $VC_PACKAGE_VERSION"
}

vc_load_docker_image() {
    local image_file
    image_file=$(find "$DELIVERY_DIR" -maxdepth 1 -name "Docker_*.tar.gz" | head -n 1)
    [[ -n "$image_file" ]] || die "No Docker image (Docker_*.tar.gz) found in $DELIVERY_DIR"

    log_info "Image : $(basename "$image_file")"
    log_info "Loading image (docker load) — this may take a few minutes ..."

    local load_output
    load_output=$(docker load -i "$image_file" 2>&1) \
        || die "Failed to load Docker image."
    log_info "$load_output"

    DOCKER_IMAGE_NAME=$(echo "$load_output" | grep "Loaded image:" | awk '{print $3}')

    if [[ -z "$DOCKER_IMAGE_NAME" ]]; then
        # Fallback: derive name from filename
        local base name_part version_part
        base=$(basename "$image_file" .tar.gz)
        base="${base#Docker_}"
        name_part=$(echo "$base" | sed 's/_[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+.*//')
        version_part=$(echo "$base" | grep -oP '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
        DOCKER_IMAGE_NAME="${name_part}:${version_part}"
    fi

    log_ok "Image loaded: $DOCKER_IMAGE_NAME"
}

vc_deploy_api() {
    # VirtualControlAPI.py is shipped in Delivery/<arch>/ — look in the current
    # architecture folder first, then fall back to the whole Delivery tree.
    local api_src
    api_src=$(find "$DELIVERY_DIR" -maxdepth 1 -name "VirtualControlAPI.py" | head -n 1)

    if [[ -z "$api_src" ]]; then
        # Fallback: search all Delivery subfolders (other architectures)
        api_src=$(find "$VC_WORK_DIR/Delivery" -name "VirtualControlAPI.py" | head -n 1)
    fi

    [[ -n "$api_src" && -f "$api_src" ]] \
        || die "VirtualControlAPI.py not found in the Virtual Control package."

    log_info "Source : $api_src"
    cp "$api_src" "$VCONTROL_API_DEST"
    chmod 750 "$VCONTROL_API_DEST"
    log_ok "VirtualControlAPI.py deployed to $VCONTROL_BASEDIR"
}

vc_setup_instance() {
    local api="python3 $VCONTROL_API_DEST"

    if $api --instance-status "$INSTANCE_NAME" 2>/dev/null | grep -q "Running\|Idle"; then
        log_warn "Instance '$INSTANCE_NAME' already exists — reconfiguring image only."
    else
        log_info "Creating instance '$INSTANCE_NAME' ..."
        $api --add-instance "$INSTANCE_NAME" || die "Failed to create instance."
        log_ok "Instance created."
    fi

    log_info "Configuring image: $DOCKER_IMAGE_NAME"
    $api --configure "$INSTANCE_NAME" set Image "$DOCKER_IMAGE_NAME" \
        || die "Failed to configure image."
    log_ok "Image configured."

    log_info "Configuring network: host"
    $api --configure "$INSTANCE_NAME" set Network host \
        || die "Failed to configure network."
    log_ok "Network set to host."

    log_info "Adding volume /tmp:/tmp ..."
    $api --configure "$INSTANCE_NAME" add Mounts "/tmp/:/tmp/" \
        || die "Failed to add /tmp mount."
    log_ok "Volume /tmp:/tmp added."

    log_info "Enabling autostart ..."
    $api --configure "$INSTANCE_NAME" set Autostart true \
        || die "Failed to enable autostart."
    log_ok "Autostart enabled (VirtualControlAPI.service registered)."
}

vc_start_instance() {
    log_info "Starting instance '$INSTANCE_NAME' ..."
    python3 "$VCONTROL_API_DEST" --run "$INSTANCE_NAME" \
        || die "Failed to start instance."
    log_ok "Instance started. Status:"
    python3 "$VCONTROL_API_DEST" --list
}

install_vcontrol() {
    log_section "MODULE 2/2 — CODESYS Virtual Control SL"

    log_section "  1/5 — Package and architecture detection"
    vc_find_package
    detect_arch

    log_section "  2/5 — Extraction"
    VC_WORK_DIR=$(extract_package "$VC_PACKAGE_FILE")
    DELIVERY_DIR="$VC_WORK_DIR/Delivery/$ARCH_DIR"
    [[ -d "$DELIVERY_DIR" ]] || die "Delivery/$ARCH_DIR folder not found in the package."

    log_section "  3/5 — Docker image loading"
    vc_load_docker_image

    log_section "  4/5 — VirtualControlAPI deployment and instance configuration"
    vc_deploy_api
    vc_setup_instance

    log_section "  5/5 — Start"
    vc_start_instance

    log_ok "Virtual Control $VC_PACKAGE_VERSION installed."
}

# ==============================================================================
# Point d'entrée principal
# ==============================================================================
main() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════╗"
    echo "  ║        CODESYS — Automated installation        ║"
    echo "  ╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    log_section "Prerequisites check"
    check_root
    check_dependencies

    trap cleanup EXIT

    local start_time=$SECONDS

    install_licenseserver
    install_vcontrol

    local elapsed=$(( SECONDS - start_time ))

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       Installation completed successfully  ✔        ║${NC}"
    printf "${GREEN}║       Duration: %-35s║${NC}\n" "${elapsed}s"
    echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    log_info "License Server  $LS_PACKAGE_VERSION → http://localhost:8080"
    log_info "                  systemctl status codesyslicenseserver"
    log_info "Virtual Control $VC_PACKAGE_VERSION → python3 $VCONTROL_API_DEST --list"
}

main
