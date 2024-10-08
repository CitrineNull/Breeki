#!/bin/bash
set -o functrace

DIRECTIVE=${1:-"--help"}

USAGE="
Usage: configure-ufw.sh [install|uninstall] (needs root or sudo)

Directives:
install         Add iptables rules for docker compatibility, and ufw rules for services
uninstall       Remove iptables rules for docker compatibility, and ufw rules for services
"

# Only allow LAN to access services, don't rely on NAT to block internet traffic
# I'm pretty sure localhost is allowed by default
add_ufw_rules() {

    # Allow local TCP IPv4 access to DNS, SMB and HTTPS
    ufw allow proto tcp from 192.168.0.0/16 to any port 10053,10443,10445
    ufw allow proto tcp from 172.16.0.0/12 to any port 10053,10443,10445
    ufw allow proto tcp from 10.0.0.0/8 to any port 10053,10443,10445

    # Allow local UDP IPv4 access to DNS
    ufw allow proto udp from 192.168.0.0/16 to any port 10053
    ufw allow proto udp from 172.16.0.0/12 to any port 10053
    ufw allow proto udp from 10.0.0.0/8 to any port 10053

    # Allow local TCP IPv6 access to DNS, SMB and HTTPS
    ufw allow proto tcp from fc00::/7 to any port 10053,10443,10445
    ufw allow proto tcp from fe80::/10 to any port 10053,10443,10445

    # Allow local UDP IPv6 access to DNS
    ufw allow proto udp from fc00::/7 to any port 10053
    ufw allow proto udp from fe80::/10 to any port 10053

}

# Remove the firewall rules
delete_ufw_rules() {

    # Allow local TCP IPv4 access to DNS, SMB and HTTPS
    ufw delete allow proto tcp from 192.168.0.0/16 to any port 10053,10443,10445
    ufw delete allow proto tcp from 172.16.0.0/12 to any port 10053,10443,10445
    ufw delete allow proto tcp from 10.0.0.0/8 to any port 10053,10443,10445

    # Allow local UDP IPv4 access to DNS
    ufw delete allow proto udp from 192.168.0.0/16 to any port 10053
    ufw delete allow proto udp from 172.16.0.0/12 to any port 10053
    ufw delete allow proto udp from 10.0.0.0/8 to any port 10053

    # Allow local TCP IPv6 access to DNS, SMB and HTTPS
    ufw delete allow proto tcp from fc00::/7 to any port 10053,10443,10445
    ufw delete allow proto tcp from fe80::/10 to any port 10053,10443,10445

    # Allow local UDP IPv6 access to DNS
    ufw delete allow proto udp from fc00::/7 to any port 10053
    ufw delete allow proto udp from fe80::/10 to any port 10053
}

# Use this with caution, I rarely use it myself
reset_everything() {

    ufw disable

    # Reset iptables to allow everything
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    iptables -t nat -F
    iptables -t mangle -F
    iptables -F
    iptables -X

    # Reset ip6tables to allow everything
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -t nat -F
    ip6tables -t mangle -F
    ip6tables -F
    ip6tables -X

    # Delete UFW rules
    echo "y" | ufw reset

    # Sensible defaults to prevent SSH lockout
    ufw default allow outgoing
    ufw default deny incoming
    
    ufw allow proto tcp from 192.168.0.0/16 to any port 22
    ufw allow proto tcp from 172.16.0.0/12 to any port 22
    ufw allow proto tcp from 10.0.0.0/8 to any port 22
    ufw allow proto tcp from fc00::/7 to any port 22
    ufw allow proto tcp from fe80::/10 to any port 22

    echo "y" | ufw enable
}

case $DIRECTIVE in 

    # Show usage instructions
    "--help" | "help")
        echo "configure-ufw.sh - UFW management script for media server ${USAGE}"
        exit 0
        ;;

    # Append rules and fix Docker/UFW compatibility
    "install")
        add_ufw_rules
        exit $?
        ;;

    # Delete rules and unfix Docker/UFW compatibility
    "uninstall")
        delete_ufw_rules
        exit $?
        ;;

    # Remove every rule on ufw and iptables, and reset to defaults
    "purge")
        reset_everything
        exit $?
        ;;

esac