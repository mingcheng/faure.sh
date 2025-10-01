# Scripts for Debian/Ubuntu

## firewall.fish

Configures iptables rules for transparent proxy and network traffic management. Sets up TPROXY rules and blocks external access to specified ports.

**Usage:**  
Requires: root privileges, [fish shell](https://fishshell.com/), and [iptables](https://netfilter.org/projects/iptables/index.html) installed and available in PATH.  
Example:  

```sh
sudo fish scripts/firewall.fish
## install_docker.fish

Automates the Docker installation process. Downloads the signed key and installs via the Aliyun repository mirror.
