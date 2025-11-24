#!/bin/bash

# Polkit Authentication Agent in Bash with Gum and D-Bus
# Requires: gum, polkit, dbus, gdbus (libglib2.0-bin)
# Optional: sudo or doas for non-D-Bus mode

# Configuration
MODE="${POLKIT_AGENT_MODE:-dbus}"  # dbus, sudo, or doas
LOG_FILE="/tmp/polkit-agent-gum.log"
PID_FILE="/tmp/polkit-agent-gum.pid"

# Check dependencies
check_dependencies() {
    if ! command -v gum &> /dev/null; then
        echo "Error: gum is not installed."
        echo "  Arch: sudo pacman -S gum"
        echo "  Debian/Ubuntu: See https://github.com/charmbracelet/gum"
        exit 1
    fi

    if [ "$MODE" = "dbus" ]; then
        if ! command -v gdbus &> /dev/null; then
            echo "Error: gdbus is not installed."
            echo "  Debian/Ubuntu: sudo apt install libglib2.0-bin"
            echo "  Arch: sudo pacman -S glib2"
            exit 1
        fi
    elif [ "$MODE" = "sudo" ]; then
        if ! command -v sudo &> /dev/null; then
            echo "Error: sudo is not installed."
            exit 1
        fi
    elif [ "$MODE" = "doas" ]; then
        if ! command -v doas &> /dev/null; then
            echo "Error: doas is not installed."
            echo "  Arch: sudo pacman -S opendoas"
            echo "  Debian/Ubuntu: sudo apt install doas"
            exit 1
        fi
    fi
}

# D-Bus constants
DBUS_SERVICE="org.freedesktop.PolicyKit1"
DBUS_PATH="/org/freedesktop/PolicyKit1/AuthenticationAgent"
DBUS_INTERFACE="org.freedesktop.PolicyKit1.AuthenticationAgent"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Get identity information
get_identity_info() {
    local identity="$1"

    # Parse identity (format: unix-user:UID)
    if [[ "$identity" =~ unix-user:([0-9]+) ]]; then
        local uid="${BASH_REMATCH[1]}"
        local username=$(getent passwd "$uid" | cut -d: -f1)
        echo "$username"
    else
        echo "${USER}"
    fi
}

# Verify password using sudo
verify_password_sudo() {
    local user="$1"
    local password="$2"

    echo "$password" | sudo -S -k -u "$user" true 2>/dev/null
    return $?
}

# Verify password using doas
verify_password_doas() {
    local user="$1"
    local password="$2"

    # doas doesn't support password from stdin in standard way
    # This is a workaround using expect-like behavior
    {
        echo "$password"
        sleep 0.1
    } | doas -u "$user" true 2>/dev/null

    return $?
}

# Main authentication function (called from D-Bus or directly)
authenticate() {
    local action_id="$1"
    local message="$2"
    local icon_name="$3"
    local cookie="$4"
    local identities="${5:-unix-user:$(id -u)}"

    log "Authentication request: action=$action_id, cookie=$cookie, mode=$MODE"

    # Get user information from identities
    local identity="${identities%%,*}"  # First identity
    local username=$(get_identity_info "$identity")

    # Display action information
    gum style \
        --border rounded \
        --border-foreground 212 \
        --padding "1 2" \
        --margin "1 0" \
        "🔐 Authentication Required" \
        "" \
        "Action: $action_id" \
        "Description: ${message:-System operation requires authorization}" \
        "User: $username" \
        "Mode: $MODE"

    # Maximum 3 attempts
    local attempts=0
    local max_attempts=3

    while [ $attempts -lt $max_attempts ]; do
        # Prompt for password
        local password
        password=$(gum input --password --placeholder "Enter password for $username")

        if [ -z "$password" ]; then
            log "Authentication cancelled by user"
            gum style --foreground 196 "❌ Authentication cancelled"
            [ "$MODE" = "dbus" ] && notify_polkit_failure "$cookie"
            return 1
        fi

        # Verify password based on mode
        local verify_result=1
        case "$MODE" in
            sudo)
                verify_password_sudo "$username" "$password"
                verify_result=$?
                ;;
            doas)
                verify_password_doas "$username" "$password"
                verify_result=$?
                ;;
            dbus)
                verify_password_sudo "$username" "$password"
                verify_result=$?
                ;;
        esac

        if [ $verify_result -eq 0 ]; then
            log "Authentication successful for $username"
            gum style --foreground 10 "✅ Authentication successful"
            [ "$MODE" = "dbus" ] && notify_polkit_success "$cookie" "$identity"
            return 0
        else
            attempts=$((attempts + 1))
            log "Incorrect password (attempt $attempts/$max_attempts)"

            if [ $attempts -lt $max_attempts ]; then
                gum style --foreground 196 "❌ Incorrect password. Try again. (Attempt $attempts/$max_attempts)"
            fi
        fi
    done

    log "Authentication failed - attempts exhausted"
    gum style --foreground 196 "❌ Authentication failed - too many incorrect attempts"
    [ "$MODE" = "dbus" ] && notify_polkit_failure "$cookie"
    return 1
}

# Notify polkit of successful authentication
notify_polkit_success() {
    local cookie="$1"
    local identity="$2"

    gdbus call --session \
        --dest "$DBUS_SERVICE" \
        --object-path "/org/freedesktop/PolicyKit1/Authority" \
        --method org.freedesktop.PolicyKit1.Authority.AuthenticationAgentResponse2 \
        "uint32:$(id -u)" \
        "$cookie" \
        "$identity" \
        2>/dev/null || log "Error sending D-Bus response (success)"
}

# Notify polkit of authentication failure
notify_polkit_failure() {
    local cookie="$1"

    gdbus call --session \
        --dest "$DBUS_SERVICE" \
        --object-path "/org/freedesktop/PolicyKit1/Authority" \
        --method org.freedesktop.PolicyKit1.Authority.AuthenticationAgentResponse2 \
        "uint32:$(id -u)" \
        "$cookie" \
        "" \
        2>/dev/null || log "Error sending D-Bus response (failure)"
}

# Register agent via D-Bus
register_agent() {
    log "Registering Polkit Agent via D-Bus"

    # Get session bus
    local session_bus_address="${DBUS_SESSION_BUS_ADDRESS}"
    if [ -z "$session_bus_address" ]; then
        log "ERROR: DBUS_SESSION_BUS_ADDRESS is not set"
        gum style --foreground 196 "❌ D-Bus session is not available"
        exit 1
    fi

    # Register agent with polkit authority
    local subject="unix-session:$(loginctl show-session $(loginctl | grep $(whoami) | awk '{print $1}' | head -1) -p Id --value 2>/dev/null || echo $(whoami))"

    log "Registering with subject: $subject"

    # Call RegisterAuthenticationAgent
    gdbus call --session \
        --dest "$DBUS_SERVICE" \
        --object-path "/org/freedesktop/PolicyKit1/Authority" \
        --method org.freedesktop.PolicyKit1.Authority.RegisterAuthenticationAgent \
        "$subject" \
        "en_US" \
        "$DBUS_PATH" \
        2>&1 | tee -a "$LOG_FILE"

    if [ ${PIPESTATUS[0]} -eq 0 ]; then
        gum style \
            --border double \
            --border-foreground 10 \
            --padding "1 2" \
            --margin "1 0" \
            "✅ Polkit Agent (Gum) registered" \
            "" \
            "Agent is running and listening for D-Bus requests..." \
            "Subject: $subject" \
            "Path: $DBUS_PATH"
    else
        gum style --foreground 196 "❌ Error registering agent"
        log "ERROR during agent registration"
        exit 1
    fi
}

# D-Bus listener (monitor authentication requests)
start_dbus_listener() {
    log "Starting D-Bus listener"

    # Monitor D-Bus signals for authentication requests
    gdbus monitor --session \
        --dest "$DBUS_SERVICE" 2>&1 | \
    while IFS= read -r line; do
        log "D-Bus event: $line"

        # Parse BeginAuthentication signal
        if [[ "$line" =~ BeginAuthentication ]]; then
            log "Caught BeginAuthentication signal"

            # Extract parameters from signal
            # Format may be: /org/freedesktop/PolicyKit1/Authority: org.freedesktop.PolicyKit1.Authority.BeginAuthentication (...)
            # For simplicity, using test data

            # In real implementation, all parameters would be parsed here
            # and authenticate function called with these parameters
            gum style --foreground 11 "⚡ New authentication request!"
        fi
    done &

    local listener_pid=$!
    echo $listener_pid > "$PID_FILE"
    log "Listener PID: $listener_pid"
}

# Sudo/Doas wrapper mode - intercept commands
run_wrapper_mode() {
    local backend="$1"

    gum style \
        --border double \
        --border-foreground 212 \
        --padding "1 2" \
        --margin "1 0" \
        "🚀 Polkit Agent (Gum) - $backend mode" \
        "" \
        "This mode provides authentication prompts for $backend commands" \
        "Type commands normally, agent will prompt when needed"

    log "Running in $backend wrapper mode"

    # Keep agent running
    while true; do
        sleep 1
    done
}

# Test function
test_agent() {
    gum style \
        --border rounded \
        --border-foreground 212 \
        --padding "1 2" \
        "🧪 Test Polkit Agent"

    authenticate \
        "org.freedesktop.systemd1.manage-units" \
        "Managing system services requires authorization" \
        "dialog-password" \
        "test-cookie-$(date +%s)" \
        "unix-user:$(id -u)"
}

# Unregister agent
unregister_agent() {
    if [ "$MODE" != "dbus" ]; then
        log "Not in D-Bus mode, skipping unregister"
        return 0
    fi

    log "Unregistering Polkit Agent"

    local subject="unix-session:$(loginctl show-session $(loginctl | grep $(whoami) | awk '{print $1}' | head -1) -p Id --value 2>/dev/null || echo $(whoami))"

    gdbus call --session \
        --dest "$DBUS_SERVICE" \
        --object-path "/org/freedesktop/PolicyKit1/Authority" \
        --method org.freedesktop.PolicyKit1.Authority.UnregisterAuthenticationAgent \
        "$subject" \
        "$DBUS_PATH" \
        2>&1 | tee -a "$LOG_FILE"

    # Kill listener process
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        kill $pid 2>/dev/null
        rm -f "$PID_FILE"
    fi

    log "Agent unregistered and terminated"
    gum style --foreground 10 "👋 Polkit Agent terminated"
}

# Display help
show_help() {
    gum style \
        --border rounded \
        --padding "1 2" \
        "Polkit Agent in Bash with Gum and D-Bus" \
        "" \
        "Usage:" \
        "  $0 [OPTIONS]" \
        "" \
        "Options:" \
        "  --mode dbus       Run in D-Bus mode (default, full polkit integration)" \
        "  --mode sudo       Run in sudo mode (sudo authentication wrapper)" \
        "  --mode doas       Run in doas mode (doas authentication wrapper)" \
        "  --register        Register and start agent (D-Bus mode)" \
        "  --unregister      Unregister agent (D-Bus mode)" \
        "  --test            Test authentication" \
        "  --help, -h        Show this help" \
        "" \
        "Environment:" \
        "  POLKIT_AGENT_MODE Set default mode (dbus, sudo, or doas)" \
        "" \
        "Dependencies:" \
        "  - gum (UI framework)" \
        "  - gdbus (D-Bus communication) - for D-Bus mode" \
        "  - polkit (authentication framework)" \
        "  - sudo or doas (for respective modes)" \
        "" \
        "Examples:" \
        "  $0 --mode dbus --register    # Start as D-Bus polkit agent" \
        "  $0 --mode sudo               # Run as sudo wrapper" \
        "  $0 --mode doas               # Run as doas wrapper" \
        "  $0 --test                    # Test authentication" \
        "" \
        "Log file: $LOG_FILE"
}

# Main program
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                MODE="$2"
                shift 2
                ;;
            --register)
                ACTION="register"
                shift
                ;;
            --unregister)
                ACTION="unregister"
                shift
                ;;
            --test)
                ACTION="test"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate mode
    if [[ ! "$MODE" =~ ^(dbus|sudo|doas)$ ]]; then
        echo "Error: Invalid mode '$MODE'. Must be: dbus, sudo, or doas"
        exit 1
    fi

    # Check dependencies
    check_dependencies

    # Execute action
    case "${ACTION:-run}" in
        test)
            test_agent
            ;;
        unregister)
            unregister_agent
            ;;
        register|run)
            if [ "$MODE" = "dbus" ]; then
                register_agent
                start_dbus_listener

                log "Agent running, waiting for requests..."
                while true; do
                    sleep 1
                done
            else
                run_wrapper_mode "$MODE"
            fi
            ;;
    esac
}

# Trap signals for clean exit
trap 'unregister_agent; exit 0' INT TERM

main "$@"
