# Kernel Parameter Configuration for Soft Router

This directory contains sysctl configuration files for optimizing Linux kernel performance and network settings specifically for soft router deployments.

## Configuration Files

- `10-custom-kernel-bbr.conf` - BBR congestion control algorithm
- `10-custom-kernel-forward.conf` - IP forwarding and routing settings
- `10-custom-kernel-ipv6.conf` - IPv6 disable configuration
- `20-network-performance.conf` - Network buffer and connection optimization
- `30-security.conf` - Network security hardening settings
- `40-system-optimization.conf` - Memory and system performance tuning
- `50-traffic-optimization.conf` - Traffic shaping and QoS settings

## Usage

1. **Copy configurations:**
   ```bash
   sudo cp *.conf /etc/sysctl.d/
   ```

2. **Apply settings:**
   ```bash
   sudo sysctl --system
   ```

3. **Verify key settings:**
   ```bash
   # BBR and network performance
   sysctl net.ipv4.tcp_congestion_control
   sysctl net.core.rmem_max
   sysctl net.core.wmem_max

   # Forwarding and routing
   sysctl net.ipv4.ip_forward
   sysctl net.ipv6.conf.all.disable_ipv6

   # Security settings
   sysctl net.ipv4.conf.all.rp_filter
   sysctl net.ipv4.tcp_syncookies

   # Connection tracking
   sysctl net.netfilter.nf_conntrack_max
   ```

4. **Monitor performance:**
   ```bash
   # Check network statistics
   ss -tuln
   netstat -i
   cat /proc/net/sockstat

   # Monitor connection tracking
   cat /proc/sys/net/netfilter/nf_conntrack_count
   cat /proc/sys/net/netfilter/nf_conntrack_max
   ```

## Notes

- BBR requires Linux kernel 4.9+
- IPv6 is disabled to reduce complexity and potential security issues
- Connection tracking settings are optimized for NAT scenarios
- Some settings may need adjustment based on specific hardware and traffic patterns
- Monitor system resources after applying configurations
- Consider network interface queue settings (`ethtool -l <interface>`) for multi-queue optimization
