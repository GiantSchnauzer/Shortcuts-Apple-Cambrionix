#!/bin/bash
set -euo pipefail

###############################################################################
# Jamf Pro - Homebrew Bootstrap for Apple Silicon
# - Runs as root via Jamf
# - Requires an active logged-in GUI user
# - Installs Xcode Command Line Tools
# - Installs Homebrew for that user
# - Installs required formulae
# - Logs to both:
#   1. /private/var/log/brew_installer.log
#   2. Jamf policy logs
###############################################################################

SCRIPT_VERSION="1.1.2"

LOG="/private/var/log/brew_installer.log"
mkdir -p "/private/var/log" || exit 1
touch "$LOG" || exit 1
chown root:wheel "$LOG" || true
chmod 644 "$LOG" || true

exec > >(/usr/bin/tee -a "$LOG") 2>&1

log() {
    /bin/echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

log "============================================================"
log "Homebrew bootstrap starting"
log "Version: $SCRIPT_VERSION"
log "============================================================"

###############################################################################
# Validate platform
###############################################################################
ARCH="$(/usr/bin/uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
    fail "This script is for Apple silicon only. Detected architecture: $ARCH"
fi
log "Validated architecture: $ARCH"

###############################################################################
# Detect logged-in GUI user
###############################################################################
CURRENT_USER="$(/usr/bin/stat -f "%Su" /dev/console 2>/dev/null || true)"
if [[ -z "${CURRENT_USER}" || "${CURRENT_USER}" == "root" ]]; then
    fail "No logged-in GUI user detected. Run this policy only when a user is actively logged in."
fi

USER_UID="$(/usr/bin/id -u "$CURRENT_USER" 2>/dev/null || true)"
USER_HOME="$(/usr/bin/dscl . -read "/Users/$CURRENT_USER" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}')"

if [[ -z "${USER_UID:-}" ]]; then
    fail "Could not determine UID for user $CURRENT_USER"
fi

if [[ -z "${USER_HOME:-}" || ! -d "$USER_HOME" ]]; then
    fail "Could not determine a valid home directory for user $CURRENT_USER"
fi

log "Detected GUI user: $CURRENT_USER"
log "Detected UID: $USER_UID"
log "Detected HOME: $USER_HOME"

###############################################################################
# Homebrew config
###############################################################################
BREW_PREFIX="/opt/homebrew"
BREW_BIN="$BREW_PREFIX/bin/brew"
ZPROFILE="$USER_HOME/.zprofile"

BREW_FORMULAE=(
    jq
    bash
    imagemagick
    capstone
    libimobiledevice
    libtool
    autoconf
    automake
    pkg-config
    libimobiledevice-glue
    libirecovery
)

BREW_TAP="blacktop/tap"

BREW_TAP_FORMULAE=(
    ipsw
)

###############################################################################
# Helpers
###############################################################################
run_as_user() {
    local CMD="$1"

    /bin/launchctl asuser "$USER_UID" /usr/bin/sudo -u "$CURRENT_USER" \
        /usr/bin/env \
        HOME="$USER_HOME" \
        USER="$CURRENT_USER" \
        LOGNAME="$CURRENT_USER" \
        PATH="$BREW_PREFIX/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        /bin/bash -lc "$CMD"
}

ensure_zprofile() {
    if [[ ! -f "$ZPROFILE" ]]; then
        /usr/bin/touch "$ZPROFILE"
        /usr/sbin/chown "$CURRENT_USER":staff "$ZPROFILE" || true
        /bin/chmod 644 "$ZPROFILE" || true
        log "Created $ZPROFILE"
    fi
}

append_shellenv_if_needed() {
    ensure_zprofile

    if ! /usr/bin/grep -q 'eval "\$(/opt/homebrew/bin/brew shellenv)"' "$ZPROFILE" 2>/dev/null; then
        /bin/echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$ZPROFILE"
        /usr/sbin/chown "$CURRENT_USER":staff "$ZPROFILE" || true
        log "Added Homebrew shellenv to $ZPROFILE"
    else
        log "Homebrew shellenv already present in $ZPROFILE"
    fi
}

###############################################################################
# Command Line Tools
###############################################################################

macOSVersionMajor=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $1}')
macOSVersionMinor=$(/usr/bin/sw_vers -productVersion | /usr/bin/awk -F. '{print $2}')

xcode_check () {
  xcodeSelectCheck=$(/usr/bin/xcode-select --print-path 2>&1)
  if [ "$xcodeSelectCheck" = "/Library/Developer/CommandLineTools" ]; then
    xcodeCLI="installed"
  else
    xcodeCLI="missing"
  fi
}

check_macos () {
  if [ "$macOSVersionMajor" -lt 10 ]; then
    echo "❌ ERROR: This Mac is running an incompatible operating system $(/usr/bin/sw_vers -productVersion)), unable to proceed."
    exit 72
  fi
}

install_command_line_tools() {
    xcode_check

    if [ "$xcodeCLI" = "installed" ]; then
      echo "Xcode Command Line Tools already installed, no action required."
      return 0
    else
      /usr/bin/xcode-select --reset
    fi

    check_macos

    /usr/bin/touch "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"

    if [ "$macOSVersionMajor" -eq 10 ] && [ "$macOSVersionMinor" -lt 15 ]; then
      xcodeCommandLineTools=$(/usr/sbin/softwareupdate --list 2>&1 | \
        /usr/bin/awk -F"[*] " '/\* Command Line Tools/ {print $NF}' | \
        /usr/bin/sed 's/^ *//' | \
        /usr/bin/tail -1)
    else
      xcodeCommandLineTools=$(/usr/sbin/softwareupdate --list 2>&1 | \
        /usr/bin/awk -F: '/Label: Command Line Tools for Xcode/ {print $NF}' | \
        /usr/bin/sed 's/^ *//' | \
        /usr/bin/tail -1)
    fi

    /usr/sbin/softwareupdate --install "$xcodeCommandLineTools"

    xcode_check

    if [ "$xcodeCLI" = "missing" ]; then
      echo "❌ ERROR: Xcode Command Line Tool install was unsuccessful."
      exit 1
    else
      /bin/rm -f "/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress"
      echo "✅ Installed Xcode Command Line Tools."
    fi
}

###############################################################################
# Homebrew install
###############################################################################
install_homebrew() {
    if [[ -x "$BREW_BIN" ]]; then
        log "Homebrew already installed at $BREW_BIN"
        return 0
    fi

    log "Homebrew not found. Installing..."

    run_as_user '/bin/bash -c "$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

    if [[ ! -x "$BREW_BIN" ]]; then
        fail "Homebrew installation failed. Expected binary not found at $BREW_BIN"
    fi

    log "Homebrew installed successfully."
}

verify_brew() {
    [[ -x "$BREW_BIN" ]] || fail "Homebrew binary not found at expected path: $BREW_BIN"

    local BREW_VERSION
    BREW_VERSION="$(run_as_user "\"$BREW_BIN\" --version | /usr/bin/head -n 1")"
    log "Using $BREW_VERSION"
}

###############################################################################
# Brew operations
###############################################################################
tap_if_needed() {
    local TAP="$1"

    if run_as_user "\"$BREW_BIN\" tap | /usr/bin/grep -qx \"$TAP\""; then
        log "Tap already present: $TAP"
    else
        log "Adding tap: $TAP"
        run_as_user "\"$BREW_BIN\" tap \"$TAP\""
    fi
}

brew_update() {
    log "Running brew update"
    run_as_user "\"$BREW_BIN\" update"
}

install_formula() {
    local FORMULA="$1"

    if run_as_user "\"$BREW_BIN\" list --formula \"$FORMULA\" >/dev/null 2>&1"; then
        log "Formula already installed: $FORMULA"
    else
        log "Installing formula: $FORMULA"
        run_as_user "\"$BREW_BIN\" install \"$FORMULA\""
    fi
}

install_required_formulae() {
    local FORMULA

    for FORMULA in "${BREW_FORMULAE[@]}"; do
        install_formula "$FORMULA"
    done

    for FORMULA in "${BREW_TAP_FORMULAE[@]}"; do
        install_formula "$FORMULA"
    done
}

brew_upgrade() {
    log "Running brew upgrade"
    run_as_user "\"$BREW_BIN\" upgrade"
}

###############################################################################
# Main
###############################################################################
install_command_line_tools
install_homebrew
append_shellenv_if_needed
verify_brew
brew_update
tap_if_needed "$BREW_TAP"
install_required_formulae
brew_upgrade

log "============================================================"
log "Homebrew bootstrap completed successfully"
log "============================================================"

exit 0
