#!/usr/bin/with-contenv bashio

# Initialize environment for Claude Code CLI
init_environment() {
    # Determine the best directory for persistent storage
    local config_base
    if [ -d "/config" ] && [ -w "/config" ]; then
        config_base="/config"
        bashio::log.info "Using /config for persistent storage"
    elif [ -d "/data" ] && [ -w "/data" ]; then
        config_base="/data"
        bashio::log.warning "Using /data for persistent storage (fallback)"
    else
        config_base="/tmp"
        bashio::log.warning "Using /tmp for storage (non-persistent fallback)"
        bashio::log.error "No persistent storage available - authentication will not persist!"
    fi

    # Create the claude-config directory
    local claude_config_dir="${config_base}/claude-config"
    if ! mkdir -p "$claude_config_dir"; then
        bashio::log.error "Failed to create claude config directory: $claude_config_dir"
        bashio::log.info "Available directories and permissions:"
        ls -la / | head -20
        exit 1
    fi
    chmod 755 "$claude_config_dir"

    # Create subdirectories for different authentication storage locations
    mkdir -p "$claude_config_dir/anthropic"
    mkdir -p "$claude_config_dir/cache"
    mkdir -p "$claude_config_dir/npm"
    mkdir -p "$claude_config_dir/node"

    # Export the config directory for use by other functions
    export CLAUDE_CONFIG_BASE="$config_base"
    export CLAUDE_CONFIG_DIR="$claude_config_dir"

    # Set up Claude Code CLI config directory
    mkdir -p /root/.config
    mkdir -p /root/.cache
    mkdir -p /root/.npm
    mkdir -p /root/.local/share
    
    # Remove existing links if they exist and create fresh symlinks
    rm -rf /root/.config/anthropic
    rm -rf /root/.anthropic
    rm -rf /root/.cache/anthropic
    rm -rf /root/.npm/anthropic
    rm -rf /root/.local/share/anthropic
    
    # Create symlinks for all potential authentication storage locations
    ln -sf "$claude_config_dir/anthropic" /root/.config/anthropic
    ln -sf "$claude_config_dir/anthropic" /root/.anthropic
    ln -sf "$claude_config_dir/cache" /root/.cache/anthropic
    ln -sf "$claude_config_dir/npm" /root/.npm/anthropic
    ln -sf "$claude_config_dir/node" /root/.local/share/anthropic

    # Ensure proper permissions on any existing credential files
    find "$claude_config_dir" -type f \( -name "session_key" -o -name "client.json" -o -name "*.token" -o -name "auth*" \) -exec chmod 600 {} \; 2>/dev/null || true

    # Set comprehensive environment variables for Claude Code CLI
    export ANTHROPIC_CONFIG_DIR="$claude_config_dir/anthropic"
    export ANTHROPIC_HOME="$claude_config_dir"
    export HOME="/root"
    export XDG_CONFIG_HOME="/root/.config"
    export XDG_CACHE_HOME="/root/.cache"
    export XDG_DATA_HOME="/root/.local/share"
    
    bashio::log.info "Credential directories initialized:"
    bashio::log.info "  - Base directory: $config_base"
    bashio::log.info "  - Primary config: $claude_config_dir/anthropic"
    bashio::log.info "  - Cache: $claude_config_dir/cache"
    bashio::log.info "  - NPM: $claude_config_dir/npm"
    bashio::log.info "  - Node data: $claude_config_dir/node"
}

# Install required tools
install_tools() {
    bashio::log.info "Installing additional tools..."
    if ! apk add --no-cache ttyd jq curl; then
        bashio::log.error "Failed to install required tools"
        exit 1
    fi
    bashio::log.info "Tools installed successfully"
}

# Setup session picker script
setup_session_picker() {
    # Copy session picker script from built-in location
    if [ -f "/opt/scripts/claude-session-picker.sh" ]; then
        if ! cp /opt/scripts/claude-session-picker.sh /usr/local/bin/claude-session-picker; then
            bashio::log.error "Failed to copy claude-session-picker script"
            exit 1
        fi
        chmod +x /usr/local/bin/claude-session-picker
        bashio::log.info "Session picker script installed successfully"
    else
        bashio::log.warning "Session picker script not found, using auto-launch mode only"
    fi
}

# Monitor and backup authentication files
setup_auth_monitoring() {
    # Create a background process that monitors for new authentication files
    cat > /usr/local/bin/claude-auth-monitor.sh << 'EOF'
#!/bin/bash

# Monitor for authentication files and copy them to persistent storage
monitor_auth_files() {
    local search_dirs=(
        "/root/.config"
        "/root/.cache" 
        "/root/.local/share"
        "/root/.anthropic"
        "/root/.npm"
        "/tmp"
    )
    
    local auth_patterns=(
        "*session*"
        "*token*"
        "*auth*"
        "*claude*"
        "*anthropic*"
        "client.json"
        "credentials*"
    )
    
    for dir in "${search_dirs[@]}"; do
        if [ -d "$dir" ]; then
            for pattern in "${auth_patterns[@]}"; do
                find "$dir" -name "$pattern" -type f -newer /etc/passwd 2>/dev/null | while read -r file; do
                    # Skip if it's already a symlink to our persistent storage
                    if [ ! -L "$file" ] && [[ "$file" != *"$CLAUDE_CONFIG_DIR"* ]]; then
                        # Determine relative path and copy to persistent storage
                        rel_path="${file#/root/}"
                        target_dir="$CLAUDE_CONFIG_DIR/discovered/$(dirname "$rel_path")"
                        mkdir -p "$target_dir"
                        cp "$file" "$target_dir/" 2>/dev/null && echo "Backed up: $file"
                    fi
                done
            done
        fi
    done
}

# Run monitoring in background
while true; do
    monitor_auth_files
    sleep 30
done
EOF

    chmod +x /usr/local/bin/claude-auth-monitor.sh
    
    # Start the auth monitoring in background
    nohup /usr/local/bin/claude-auth-monitor.sh > "$CLAUDE_CONFIG_DIR/auth-monitor.log" 2>&1 &
    bashio::log.info "Authentication monitoring started"
}

# Restore previously discovered authentication files
restore_auth_files() {
    local discovered_dir="$CLAUDE_CONFIG_DIR/discovered"
    
    if [ -d "$discovered_dir" ]; then
        bashio::log.info "Restoring previously discovered authentication files..."
        
        # Restore files to their original locations
        find "$discovered_dir" -type f 2>/dev/null | while read -r file; do
            # Extract the relative path from the discovered directory
            rel_path="${file#$discovered_dir/}"
            target_file="/root/$rel_path"
            target_dir="$(dirname "$target_file")"
            
            # Create target directory if it doesn't exist
            mkdir -p "$target_dir"
            
            # Copy the file back, but don't overwrite symlinks
            if [ ! -L "$target_file" ]; then
                cp "$file" "$target_file" 2>/dev/null && echo "Restored: $target_file"
                chmod 600 "$target_file" 2>/dev/null || true
            fi
        done
        
        bashio::log.info "Authentication file restoration completed"
    else
        bashio::log.info "No previously discovered authentication files to restore"
    fi
}

# Determine Claude launch command based on configuration
get_claude_launch_command() {
    local auto_launch_claude
    
    # Get configuration value, default to true for backward compatibility
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true')
    
    if [ "$auto_launch_claude" = "true" ]; then
        # Original behavior: auto-launch Claude directly
        echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && node \$(which claude)"
    else
        # New behavior: show interactive session picker
        if [ -f /usr/local/bin/claude-session-picker ]; then
            echo "clear && /usr/local/bin/claude-session-picker"
        else
            # Fallback if session picker is missing
            bashio::log.warning "Session picker not found, falling back to auto-launch"
            echo "clear && echo 'Welcome to Claude Terminal!' && echo '' && echo 'Starting Claude...' && sleep 1 && node \$(which claude)"
        fi
    fi
}


# Start main web terminal
start_web_terminal() {
    local port=7681
    bashio::log.info "Starting web terminal on port ${port}..."
    
    # Log environment information for debugging
    bashio::log.info "Environment variables:"
    bashio::log.info "ANTHROPIC_CONFIG_DIR=${ANTHROPIC_CONFIG_DIR}"
    bashio::log.info "HOME=${HOME}"

    # Get the appropriate launch command based on configuration
    local launch_command
    launch_command=$(get_claude_launch_command)
    
    # Log the configuration being used
    local auto_launch_claude
    auto_launch_claude=$(bashio::config 'auto_launch_claude' 'true')
    bashio::log.info "Auto-launch Claude: ${auto_launch_claude}"
    
    # Run ttyd with improved configuration
    exec ttyd \
        --port "${port}" \
        --interface 0.0.0.0 \
        --writable \
        bash -c "$launch_command"
}

# Main execution
main() {
    bashio::log.info "Initializing Claude Terminal add-on..."
    
    init_environment
    restore_auth_files
    install_tools
    setup_session_picker
    setup_auth_monitoring
    start_web_terminal
}

# Execute main function
main "$@"