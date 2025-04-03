#!/bin/bash
set -e

# Check for required dependencies
check_dependency() {
  if ! command -v "$1" &> /dev/null; then
    echo "Error: $1 is not installed or not in PATH" >&2
    exit 1
  fi
}

check_dependency "screen"
check_dependency "socat"
check_dependency "haproxy"
check_dependency "jq"

CONFIG_FILE="tunnels_config.json"
HAPROXY_CONFIG="haproxy.cfg"

# Check command line arguments
if [ $# -ne 1 ] || [ "$1" != "up" -a "$1" != "down" ]; then
  echo "Usage: $0 [up|down]"
  exit 1
fi

COMMAND="$1"

# Create _build directory if it doesn't exist
mkdir -p _build

# Function to clean up existing tunnels
cleanup_tunnels() {
  echo "Cleaning up existing tunnels..."

  # Get the screen session PID
  SCREEN_PID=$(pgrep -f "SCREEN -dmS tunnels" || true)
  
  if [ -n "$SCREEN_PID" ]; then
    # Get all child processes except sleep infinity
    CHILD_PIDS=$(pgrep -P $SCREEN_PID | xargs -I{} ps -o pid= -o cmd= -p {} | grep -v "sleep infinity" | awk '{print $1}')
    
    # Kill haproxy processes first
    for PID in $CHILD_PIDS; do
      if ps -p $PID -o cmd= | grep -q "haproxy"; then
        echo "Stopping haproxy process (PID: $PID)"
        kill $PID 2>/dev/null || true
      fi
    done
    
    # Kill socat processes next
    for PID in $CHILD_PIDS; do
      if ps -p $PID -o cmd= | grep -q "socat"; then
        echo "Stopping socat process (PID: $PID)"
        kill $PID 2>/dev/null || true
      fi
    done
    
    # Kill ssh processes last
    for PID in $CHILD_PIDS; do
      if ps -p $PID -o cmd= | grep -q "ssh"; then
        echo "Stopping ssh process (PID: $PID)"
        kill $PID 2>/dev/null || true
      fi
    done
    
    # Remove all screen windows except the main one with sleep infinity
    screen -S tunnels -Q windows | grep -v sleep | cut -d ' ' -f 1 | while read -r window; do
      screen -S tunnels -X remove $window
    done
  fi
}

# Handle the 'down' command
if [ "$COMMAND" = "down" ]; then
  cleanup_tunnels
  echo "All tunnels have been removed."
  exit 0
fi

# Handle the 'up' command
if [ "$COMMAND" = "up" ]; then
  # Check if screen session exists and is alive
  if screen -list | grep -q "tunnels"; then
    # Check if the session is dead
    if screen -list | grep -q "tunnels.*Dead"; then
      echo "Found dead screen session 'tunnels', wiping it..."
      screen -wipe >/dev/null
      SCREEN_EXISTS=false
    else
      # Try to send a command to verify the session is responsive
      if ! screen -S tunnels -X version >/dev/null 2>&1; then
        echo "Screen session 'tunnels' exists but is unresponsive, wiping it..."
        screen -wipe >/dev/null
        SCREEN_EXISTS=false
      else
        echo "Using existing screen session 'tunnels'..."
        SCREEN_EXISTS=true
      fi
    fi
  else
    SCREEN_EXISTS=false
  fi
  
  # Create a new screen session if needed
  if [ "$SCREEN_EXISTS" != "true" ]; then
    echo "Creating new screen session 'tunnels'..."
    screen -dmS tunnels sleep infinity
  fi
  
  # Clean up existing tunnels to ensure a clean state
  cleanup_tunnels
  
  # Check that all SSH keys exist before starting any tunnels
  echo "Checking SSH keys..."
  MISSING_KEYS=0
  KEYS_CHECKED=()
  
  jq -c '.tunnels[]' $CONFIG_FILE | while read -r tunnel; do
    ssh_key=$(echo $tunnel | jq -r '.ssh_key')
    name=$(echo $tunnel | jq -r '.name')
    
    # Expand tilde to home directory
    ssh_key="${ssh_key/#\~/$HOME}"
    
    # Skip if already checked this key
    if [[ " ${KEYS_CHECKED[*]} " =~ " ${ssh_key} " ]]; then
      continue
    fi
    
    if [ ! -f "$ssh_key" ]; then
      echo "Error: SSH key '$ssh_key' for tunnel '$name' does not exist"
      MISSING_KEYS=$((MISSING_KEYS + 1))
    else
      KEYS_CHECKED+=("$ssh_key")
    fi
  done
  
  if [ $MISSING_KEYS -gt 0 ]; then
    echo "Found $MISSING_KEYS missing SSH keys. Please check your configuration."
    exit 1
  fi
  
  # Check SSH version to determine which StrictHostKeyChecking option to use
  SSH_VERSION=$(ssh -V 2>&1 | cut -d' ' -f1 | cut -d'_' -f2 | cut -d'p' -f1)
  SSH_MAJOR=$(echo $SSH_VERSION | cut -d. -f1)
  SSH_MINOR=$(echo $SSH_VERSION | cut -d. -f2)
  
  # SSH 7.6+ supports 'accept-new', older versions need 'no'
  if [ "$SSH_MAJOR" -ge 8 ] || ([ "$SSH_MAJOR" -eq 7 ] && [ "$SSH_MINOR" -ge 6 ]); then
    SSH_HOSTKEY_OPTION="accept-new"
  else
    SSH_HOSTKEY_OPTION="no"
  fi
  
  # Generate HAProxy config header
  cat > $HAPROXY_CONFIG << EOF
global
    maxconn 256

defaults
    mode http
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
EOF

  # Process each tunnel in the configuration
  jq -c '.tunnels[]' $CONFIG_FILE | while read -r tunnel; do
    name=$(echo $tunnel | jq -r '.name')
    remote_host=$(echo $tunnel | jq -r '.remote_host')
    remote_user=$(echo $tunnel | jq -r '.remote_user')
    ssh_key=$(echo $tunnel | jq -r '.ssh_key')
    target=$(echo $tunnel | jq -r '.target')
    port=$(echo $tunnel | jq -r '.port')
    local_port=$(echo $tunnel | jq -r '.local_port')
    
    socat_port=$((local_port + 1))
    haproxy_port=$((local_port + 2))
    
    echo "Setting up tunnel for $name ($target)"
    
    # Start SSH tunnel in a screen window
    screen -S tunnels -X screen -t ssh_${name} ssh -N -L ${local_port}:${target}:${port} -o StrictHostKeyChecking=${SSH_HOSTKEY_OPTION} -o UserKnownHostsFile=~/.ssh/known_hosts -o ServerAliveInterval=60 -o ExitOnForwardFailure=yes -i $ssh_key ${remote_user}@${remote_host}
    
    # Wait for SSH to establish
    sleep 2
    
    # Start socat in a screen window
    screen -S tunnels -X screen -t socat_${name} socat -v TCP-LISTEN:${socat_port},fork,reuseaddr OPENSSL:localhost:${local_port},verify=0
    
    # Add to HAProxy config
    cat >> $HAPROXY_CONFIG << EOF

frontend ${name}_proxy
  bind 127.0.0.1:${haproxy_port}
  mode http
  option http-server-close
  http-request set-header Host ${target}
  default_backend ${name}_backend

backend ${name}_backend
  mode http
  server tunnel 127.0.0.1:${socat_port}
EOF

    echo "Service $name available at http://localhost:${haproxy_port}"
  done

  # Start HAProxy in a screen window
  screen -S tunnels -X screen -t haproxy haproxy -f $HAPROXY_CONFIG
  
  echo "All tunnels are now active. Use 'screen -r tunnels' to view the session."
  exit 0
fi
