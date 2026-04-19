#!/usr/bin/env bash
# =============================================================================
# firewall-setup.sh — iptables rules for a WordPress/MySQL server on Debian 13
# Allows: SSH (22), HTTP (80), HTTPS (443) inbound
# Blocks: everything else inbound; MySQL locked to localhost only
# Run as root.
# =============================================================================

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
info()  { echo "  [INFO]  $*"; }
ok()    { echo "  [ OK ]  $*"; }
die()   { echo "  [FAIL]  $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (sudo $SCRIPT_NAME)"

# --------------------------------------------------------------------------- #
# 0. Persist tool — install iptables-persistent if absent
# --------------------------------------------------------------------------- #
if ! dpkg -l iptables-persistent &>/dev/null; then
    info "Installing iptables-persistent …"
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
fi

# --------------------------------------------------------------------------- #
# 1. Flush existing rules and set default DROP policies
# --------------------------------------------------------------------------- #
info "Flushing existing rules …"
iptables  -F
iptables  -X
iptables  -Z
ip6tables -F
ip6tables -X
ip6tables -Z

info "Setting default policies to DROP …"
iptables  -P INPUT   DROP
iptables  -P FORWARD DROP
iptables  -P OUTPUT  ACCEPT   # outbound unrestricted

ip6tables -P INPUT   DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT  ACCEPT

# --------------------------------------------------------------------------- #
# 2. Loopback — always allow
# --------------------------------------------------------------------------- #
info "Allowing loopback …"
iptables  -A INPUT -i lo -j ACCEPT
ip6tables -A INPUT -i lo -j ACCEPT

# --------------------------------------------------------------------------- #
# 3. Stateful — allow established / related traffic back in
# --------------------------------------------------------------------------- #
info "Allowing established / related connections …"
iptables  -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# --------------------------------------------------------------------------- #
# 4. ICMP — allow ping (rate-limited) and essential ICMPv6
# --------------------------------------------------------------------------- #
info "Allowing ICMP (ping) …"
iptables  -A INPUT -p icmp  --icmp-type echo-request \
          -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# ICMPv6 types required for IPv6 to function correctly
for TYPE in neighbour-solicitation neighbour-advertisement \
            router-solicitation router-advertisement; do
    ip6tables -A INPUT -p ipv6-icmp --icmpv6-type "$TYPE" -j ACCEPT
done
ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request \
          -m limit --limit 5/s --limit-burst 10 -j ACCEPT

# --------------------------------------------------------------------------- #
# 5. SSH — rate-limited to slow brute-force attempts
# --------------------------------------------------------------------------- #
info "Allowing SSH (port 22) with connection rate-limit …"
iptables  -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
          -m recent --set --name SSH_GUARD
iptables  -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
          -m recent --update --seconds 60 --hitcount 6 \
          --name SSH_GUARD -j DROP
iptables  -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
          -m recent --set --name SSH6_GUARD
ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW \
          -m recent --update --seconds 60 --hitcount 6 \
          --name SSH6_GUARD -j DROP
ip6tables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT

# --------------------------------------------------------------------------- #
# 6. HTTP + HTTPS — web traffic for WordPress
# --------------------------------------------------------------------------- #
info "Allowing HTTP (80) and HTTPS (443) …"
for PORT in 80 443; do
    iptables  -A INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW -j ACCEPT
    ip6tables -A INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW -j ACCEPT
done

# --------------------------------------------------------------------------- #
# 7. MySQL — localhost only (iptables OUTPUT is open, so this just
#    ensures no external host can reach port 3306 even if mysqld
#    were misconfigured to bind 0.0.0.0)
# --------------------------------------------------------------------------- #
info "Blocking external access to MySQL (3306) …"
iptables  -A INPUT -p tcp --dport 3306 ! -i lo -j DROP
ip6tables -A INPUT -p tcp --dport 3306 ! -i lo -j DROP

# --------------------------------------------------------------------------- #
# 8. Log and drop everything else
# --------------------------------------------------------------------------- #
info "Adding catch-all LOG + DROP rules …"
iptables  -A INPUT -m limit --limit 5/min \
          -j LOG --log-prefix "[ipt-DROP] " --log-level 4
iptables  -A INPUT -j DROP

ip6tables -A INPUT -m limit --limit 5/min \
          -j LOG --log-prefix "[ip6t-DROP] " --log-level 4
ip6tables -A INPUT -j DROP

# --------------------------------------------------------------------------- #
# 9. Save rules so they survive reboots
# --------------------------------------------------------------------------- #
info "Saving rules …"
netfilter-persistent save

# --------------------------------------------------------------------------- #
# 10. Summary
# --------------------------------------------------------------------------- #
echo ""
echo "============================================================="
echo "  Firewall rules applied and persisted."
echo "============================================================="
echo ""
echo "  IPv4 INPUT chain:"
iptables  -L INPUT -n --line-numbers -v 2>/dev/null | sed 's/^/    /'
echo ""
echo "  IPv6 INPUT chain:"
ip6tables -L INPUT -n --line-numbers -v 2>/dev/null | sed 's/^/    /'
echo ""
ok "Done. To inspect rules at any time:"
echo "     iptables  -L -n -v --line-numbers"
echo "     ip6tables -L -n -v --line-numbers"
echo ""
echo "  To unblock an IP manually (e.g. after SSH lock-out):"
echo "     iptables -D INPUT -s <IP> -j DROP"
echo ""
