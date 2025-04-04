# RPC Tunnels

A bash utility that creates secure SSH-based tunnels to access network-restricted services. It allows you to connect to services that have IP restrictions by proxying requests through authorized remote systems. Any request to a configured local port is securely forwarded to the target service, appearing as if the connection originated from the authorized system.

## Why SSH Tunnels Over VPN

While VPN solutions like Wireguard can provide similar functionality, this approach offers distinct advantages:

- **Minimal Dependencies**: Only requires an SSH server on the authorized system - no additional VPN software installation needed
- **Selective Routing**: Only specific traffic to designated HTTP/HTTPS services is routed through the tunnel, unlike VPNs which typically route all traffic

## Use Case: VSCode Devcontainer Development

A perfect example is development with VSCode devcontainers where your service needs to access network-restricted HTTP/HTTPS endpoints:

- No need to configure VPN on the host system or within the devcontainer
- Establish lightweight SSH tunnels directly in the devcontainer
- Host system traffic remains unaffected
- General container traffic still flows through normal routes
- Only specific service requests are tunneled through the authorized system

## Quick Start

1. Create a configuration file by copying and modifying the example:
   ```bash
   cp tunnels_config.example.json tunnels_config.json
   ```
   Then edit `tunnels_config.json` with your specific tunnel configurations

2. Start the tunnels:
   ```bash
   ./rpc-tunnels.sh up
   ```

3. Stop the tunnels when done:
   ```bash
   ./rpc-tunnels.sh down
   ```

## Dependencies

The script relies on several key components to create and manage the tunnels:

- **screen**: Terminal session manager that runs and maintains all tunnel processes
- **socat**: Handles SSL termination and bidirectional data transfer between sockets
- **haproxy**: Provides HTTP routing and header management for tunneled connections
- **jq**: JSON processor used to parse the tunnel configuration file

```bash
sudo apt-get update
sudo apt-get install -y screen socat haproxy jq
```

## Configuration File

The script uses a JSON configuration file (`tunnels_config.json`) to define the tunnels. You can configure multiple endpoints in a single configuration file.

> **Note**: If the configuration file is not in the same directory as the script, you must modify the `CONFIG_FILE` variable in the script to specify the correct path.

Each tunnel configuration requires the following fields:

| Field | Description |
|-------|-------------|
| `name` | A unique identifier for the tunnel |
| `remote_host` | Hostname or IP of the authorized system that will proxy the connection |
| `remote_user` | SSH username for the remote system |
| `ssh_key` | Path to the SSH private key for authentication |
| `target` | The hostname of the restricted service you want to access |
| `port` | The port of the restricted service (typically 443 for HTTPS) |
| `local_port` | The initial local port to use for the tunnel |

Example configuration:
```json
{
  "tunnels": [
    {
      "name": "api_service",
      "remote_host": "jump-server.example.com",
      "remote_user": "tunnel_user",
      "ssh_key": "~/.ssh/id_rsa",
      "target": "restricted-api.example.com",
      "port": 443,
      "local_port": 18008
    },
    {
      "name": "another_service",
      "remote_host": "jump-server.example.com",
      "remote_user": "tunnel_user",
      "ssh_key": "~/.ssh/id_rsa",
      "target": "another-api.example.com",
      "port": 8545,
      "local_port": 18018
    }
  ]
}
```

When configured, each service will be accessible at `http://localhost:(local_port+2)`. For example, with the above configuration, you can access:
- `api_service` at http://localhost:18010
- `another_service` at http://localhost:18030

## SSH Key Generation

For secure authentication, it's recommended to use ED25519 SSH keys:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/tunnel_key -C "tunnel access key"
```

This will generate:
- Private key: `~/.ssh/tunnel_key`
- Public key: `~/.ssh/tunnel_key.pub`

Use the path to the private key in your configuration file's `ssh_key` field.

## Remote System Configuration

To set up the remote system for tunneling, follow these steps:

### 1. Create a Dedicated Tunnel User

Create a user specifically for tunneling with no password login:

```bash
sudo adduser --disabled-password tunnel_user
```

### 2. Configure SSH Keys

Set up the SSH directory with proper permissions:

```bash
sudo mkdir -p /home/tunnel_user/.ssh
sudo touch /home/tunnel_user/.ssh/authorized_keys
sudo chmod 700 /home/tunnel_user/.ssh
sudo chmod 600 /home/tunnel_user/.ssh/authorized_keys
```

Add your public key with restrictions:

```bash
echo 'no-pty,no-X11-forwarding,no-agent-forwarding,no-user-rc,command="/bin/false" ssh-rsa AAAAB3Nz...' | sudo tee /home/tunnel_user/.ssh/authorized_keys
```

Replace the `ssh-rsa AAAAB3Nz...` part with the content of your public key file.

Set proper ownership:

```bash
sudo chown -R tunnel_user:tunnel_user /home/tunnel_user/.ssh
```

### 3. Configure SSH Server

Modify the SSH server configuration:

```bash
sudo nano /etc/ssh/sshd_config
```

Add these lines at the end:

```
Match User tunnel_user
    AllowTcpForwarding yes
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    ForceCommand /bin/false
```

Restart the SSH service:

```bash
sudo systemctl restart sshd
```

## Additional Security Measures

Implement these additional steps to enhance security:

### 1. Lock the User Account

Prevent password login:

```bash
sudo passwd -l tunnel_user
```

### 2. Disable Shell Access

Change to a non-executable shell:

```bash
sudo usermod -s /usr/sbin/nologin tunnel_user
```

### 3. Restrict Access

Edit the access configuration:

```bash
sudo nano /etc/security/access.conf
```

Add this line:

```
- : tunnel_user : ALL EXCEPT sshd
```

Update PAM configuration:

```bash
sudo nano /etc/pam.d/login
```

Ensure this line is present and not commented:

```
account  required  pam_access.so
```

### 4. Prevent Sudo Access

Modify the sudoers file:

```bash
sudo visudo
```

Add this rule:

```
ALL ALL=(tunnel_user) !ALL
```

These configurations ensure the tunnel user can only be used for SSH tunneling and cannot log in or execute commands on the system.

## Architecture & Implementation

The script uses a single `screen` session named "tunnels" to manage all tunnel processes. This approach provides several benefits:

### Screen Session Structure

The screen session is structured as follows:

1. **SSH tunnel windows** (window name: `ssh_[tunnel_name]`)
   - One window per tunnel
   - Establishes the secure connection to the authorized remote system
   - Provides the initial port forwarding from `local_port` to the target service

2. **SOCAT windows** (window name: `socat_[tunnel_name]`)
   - One window per tunnel
   - Handles SSL termination and conversion
   - Listens on `local_port+1`

3. **Single HAProxy window** (one window for all tunnels)
   - Provides HTTP routing and header management for all tunnels
   - Exposes each service at its respective `local_port+2`

### Why Screen?

Using `screen` provides several advantages:

- **Process Management**: All tunnel processes are children of a single parent `screen` process, making them easy to track and manage
- **Persistence**: The session uses a base `sleep infinity` process that allows the session to persist across multiple script runs
- **Zombie Prevention**: Particularly useful in container environments (like devcontainers) that lack proper init systems
- **Inspection**: Allows developers to attach to the session (`screen -r tunnels`) to monitor or debug tunnel operations

### Tunnel Deactivation

When tunnels are deactivated:

1. The script locates the main `screen` session PID
2. It systematically terminates child processes in a specific order:
   - HAProxy processes first
   - SOCAT processes next
   - SSH processes last
3. All screen windows except the base window (running `sleep infinity`) are removed
4. The base `screen` session remains available for future tunnel activations

This structured approach ensures clean teardown while maintaining the ability to reuse the session, improving reliability in development environments.

## Future Development

Here are some possible enhancements for future releases:

### Tunnel Monitoring and Resilience
- Implement health checks to monitor tunnel status
- Add intelligent recovery to determine which component (SSH, SOCAT, or HAProxy) needs restarting
- Develop graceful shutdown capabilities when network connectivity is lost (useful when a developer laptop disconnects from the network)

### Selective Tunnel Activation
- Add ability to start/stop specific tunnels rather than all-or-nothing
- Support named groups of tunnels for different development scenarios

### Configuration Improvements
- Create a configuration generation tool with interactive prompts
- Redesign the configuration structure to reduce redundancy (e.g., allow common remote system, username, and SSH key across multiple endpoints)

## Acknowledgments

The initial version of this script was developed with Claude AI, and later improved using Claude IDE in Agent mode. However, it's worth noting that this wasn't a pure "vibe-coding" approach where the AI suggested all implementation details. 

In particular, the use of `screen` as a process management solution wasn't part of the AI's initial suggestions. Additional research and consultation with Claude AI helped identify `screen` as an effective way to manage the interconnected tunnel processes, especially for container environments where proper process management is crucial.

Additionally, the remote system configuration instructions in this README were also prepared with Claude AI's assistance. If you encounter any issues with the configuration or have security concerns about the recommended setup, please reach out to the project maintainers. Security is a priority, and we welcome feedback to improve these recommendations. 

These experiences with both the screen implementation and security configuration highlight an important lesson in AI-assisted development: while AI tools can provide valuable suggestions and accelerate coding significantly, critical aspects like process management and security still benefit from human expertise and deliberate architectural decisions. The most effective approach combines AI assistance with domain-specific knowledge to build robust, secure solutions.