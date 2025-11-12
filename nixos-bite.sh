#! /usr/bin/env bash
set -eo pipefail

# nixos-bite: a script for automatically converting a Linux VPS into a NixOS VPS;
# see https://codeberg.org/whitequark/nixos-bite for details. quick reference:
#  - `ssh root@${HOST} bash < nixos-bite.sh` installs NixOS, leaving the result for examination
#  - `ssh root@${HOST} bash -s reboot < nixos-bite.sh` reboots into the freshly installed NixOS
#  - `export NIX_CHANNEL=nixos-25.05` sets the nixpkgs release channel
#  - `export NIX_SETUP=/root/script.sh` arranges the script to be executed on first NixOS boot
#  - the snippet below, when used as cloud-init user data, installs and reboots into NixOS
: <<SNIP
#cloud-config
runcmd:
- 'sleep 30s' # wait for network
- 'curl https://codeberg.org/whitequark/nixos-bite/raw/branch/main/nixos-bite.sh | bash -s reboot'
SNIP

# this script is `fanfiction' of https://github.com/elitak/nixos-infect: it is inspired by and
# shares the same core operating principle (/etc/NIXOS_LUSTRATE), but significantly differs in
# scope and implementation. the author of nixos-bite is grateful for the effort that went into
# making nixos-infect.

[[ -z "$NIX_CHANNEL" ]] && NIX_CHANNEL="nixos-25.05"
[[ -z "$NIX_STATE_VERSION" ]] && NIX_STATE_VERSION="$(echo $NIX_CHANNEL | sed -r 's/[a-z-]+([0-9.]+)/\1/')"
if [[ -z "$NIX_STATE_VERSION" ]]; then echo "Provide explicit NIX_STATE_VERSION= for $NIX_CHANNEL" >&2; exit 1; fi
if [[ ! -e "$NIX_SETUP" ]]; then
  cat > /root/exampleSetup.sh <<EOF
#!/bin/sh
sleep 10s
echo -e '\n\n\e[1;32m  Welcome to NixOS!\e[0m\n' >/dev/tty1
echo -e '\e[1;33mIf NIX_SETUP= had been pointing to a script, it would run now.\e[0m\n' >/dev/tty1
EOF
  NIX_SETUP=/root/exampleSetup.sh
fi

apt-get update -y
apt-get install -y bzip2 xz-utils curl iproute2 dosfstools

rootfsdev=$(mount | grep "on / type" | awk '{ print $1 }')
rootfstype=$(mount | grep "on / type" | awk '{ print $5 }')

bootfsdev=$(mount | grep "on /boot" | awk '{ print $1 }' || true)
bootfstype=$(mount | grep "on /boot" | awk '{ print $5 }' || true)

[ "$rootfstype" = "ext2" ] && e2label "$rootfsdev" root || true
[ "$rootfstype" = "ext3" ] && e2label "$rootfsdev" root || true
[ "$rootfstype" = "ext4" ] && e2label "$rootfsdev" root || true
[ "$bootfstype" = "vfat" ] && fatlabel "$bootfsdev" boot || true

if [[ -d /sys/firmware/efi ]]; then
  bootldr="fileSystems.\"/boot\" = { device = \"$bootfsdev\"; fsType = \"$bootfstype\"; };
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = \"nodev\";
  };"
else
  grubdev=$(echo "$rootfsdev" | sed -r 's|p?[0-9]+$||')
  bootldr="boot.loader.grub.device = \"$grubdev\";"
fi

minram=4096 # MiB
curram=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
swapsz=$(( $minram - $curram ))
if [ "$curram" -lt "$minram" ]; then
  swapdev="swapDevices = [{ device = \"/swap\"; size = $swapsz; }];"
  swapoff -a
  dd if=/dev/zero of=/swap bs=1M count=$swapsz
  mkswap /swap
  swapon /swap
fi

netif=$(ip -6 address show | grep '^2:' | awk -F': ' '{print $2}')
netip6=$(ip -6 address show dev "$netif" scope global | sed -z -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|"\1/\2"|')
netgw6=$(ip -6 route show dev "$netif" default | sed -r 's|default via ([0-9a-f:]+).*|"\1"|' | head -n1)
netip4=$(ip -4 address show dev "$netif" scope global | sed -z -r 's|.*inet ([0-9.]+)/([0-9]+).*|"\1/\2"|')
netgw4=$(ip -4 route show dev "$netif" default | sed -r 's|default via ([0-9.]+).*|"\1"|' | head -n1)

route=""
[[ -n "${netgw4}" ]] && route="$route { Gateway = $netgw4; GatewayOnLink = true; }"
[[ -n "${netgw6}" ]] && route="$route { Gateway = $netgw6; }"

dns='"2620:fe::fe" "9.9.9.9"'

sshkeys=$(awk '/^[^#]*(ssh-[^#]+)$/ { print "\""$0"\"" }' < /root/.ssh/authorized_keys)

rm /etc/resolv.conf
echo $dns | sed -r 's|"([^"]+?)"\s*|nameserver \1\n|g' > /etc/resolv.conf

mkdir -p /etc/nixos
cat > /etc/nixos/configuration.nix <<EOF
{ pkgs, modulesPath, ... }: {
  system.stateVersion = "$NIX_STATE_VERSION";
  nix.settings.experimental-features = "flakes nix-command";

  # Hardware
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  fileSystems."/" = { device = "$rootfsdev"; fsType = "$rootfstype"; };
  $bootldr
  boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "xen_blkfront" ];
  boot.initrd.kernelModules = [ "nvme" ];
  boot.tmp.cleanOnBoot = true;
  $swapdev
  zramSwap.enable = true;

  # Networking
  networking = {
    useNetworkd = true;
    usePredictableInterfaceNames = true;
    hostName = "$(hostname -s)";
    domain = "$(hostname -d)";
  };
  systemd.network = {
    enable = true;
    networks."40-wan" = {
      matchConfig.Name = "en*";
      address = [ $netip6 $netip4 ];
      routes = [ $route ];
      dns = [ $dns ];
    };
  };

  # SSH
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [ $sshkeys ];

  # Setup
  systemd.services.setup = rec {
    wantedBy = [ "basic.target" ];
    after = wantedBy;
    serviceConfig = {
      Type = "oneshot";
      ConditionPathExists = "/etc/nixos/setup.sh";
      ExecStart = "/etc/nixos/setup.sh";
      ExecStartPost = "\${pkgs.coreutils}/bin/rm /etc/nixos/setup.sh";
    };
  };
}
EOF

cp "$NIX_SETUP" /etc/nixos/setup.sh
chmod +x /etc/nixos/setup.sh

mkdir -p -m 0755 /nix

addgroup --system --gid 30000 nixbld || true
for i in {1..10}; do
  adduser --system --no-create-home nixbld$i || true
  adduser nixbld$i nixbld || true
done

[[ -z "$USER" ]] && export USER=root
[[ -z "$HOME" ]] && export HOME=/root

curl -sL https://nixos.org/nix/install | sh -s -- --no-channel-add

source /root/.nix-profile/etc/profile.d/nix.sh

nix-channel --remove nixpkgs
nix-channel --add "https://nixos.org/channels/$NIX_CHANNEL" nixos
nix-channel --update

export NIXOS_CONFIG=/etc/nixos/configuration.nix

nix-env --set \
  -I nixpkgs=/root/.nix-defexpr/channels/nixos \
  -f '<nixpkgs/nixos>' \
  -p /nix/var/nix/profiles/system \
  -A system

rm -fv /nix/var/nix/profiles/default*
/nix/var/nix/profiles/system/sw/bin/nix-collect-garbage

touch /etc/NIXOS
echo etc/nixos >> /etc/NIXOS_LUSTRATE
echo etc/resolv.conf >> /etc/NIXOS_LUSTRATE
echo root/.nix-defexpr/channels >> /etc/NIXOS_LUSTRATE
(cd / && ls etc/ssh/ssh_host_*_key* || true) >> /etc/NIXOS_LUSTRATE

# place bootloader files into /boot partition only on EFI systems
if [[ -n "$bootfsdev" ]]; then
  umount $bootfsdev
  rm -fr /boot/*
  if [[ -d /sys/firmware/efi ]]; then
    mount $bootfsdev /boot
    rm -fr /boot/*
  fi
fi
/nix/var/nix/profiles/system/bin/switch-to-configuration boot

if [[ -d /sys/firmware/efi ]]; then
  echo -e "\n\e[1;35m  This is an EFI system; /boot is on $bootfsdev\e[0m\n"
else
  echo -e "\n\e[1;36m  This is a BIOS system; /boot is on $rootfsdev (same as /)\e[0m\n"
fi

exec "$@"
