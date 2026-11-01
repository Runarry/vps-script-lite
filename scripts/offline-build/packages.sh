#!/usr/bin/env bash
# Required package seeds shared by collection and disconnected acceptance.
packages=(
    apt dpkg debconf bash coreutils diffutils findutils grep sed gzip tar util-linux mount
    procps libc-bin passwd systemd cron file less gnupg binutils
    jq curl ca-certificates openssl unzip python3 iperf3 iproute2 nftables iptables
    fail2ban python3-systemd openssh-server openssh-client sudo dnsutils chrony kmod gawk
)
