#! /usr/bin/env bash
set -eo pipefail

# nixos-bite: a script for automatically converting a Linux VPS into a NixOS VPS;
# see https://codeberg.org/whitequark/nixos-bite for details. quick reference:
#  - `ssh root@${HOST} bash < nixos-bite.sh` installs NixOS, leaving the result for examination
#  - `ssh root@${HOST} bash -s reboot < nixos-bite.sh` reboots into the freshly installed NixOS
#  - `export NIX_DNS="2020:fe::10 9.9.9.10"` configures the DNS servers
#  - `export NIX_CHANNEL=nixos-25.11` sets the nixpkgs release channel
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

[[ -z "$NIX_DNS" ]] && NIX_DNS="2020:fe::10 9.9.9.10"
[[ -z "$NIX_CHANNEL" ]] && NIX_CHANNEL="nixos-25.11"
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

rootfsdev=$(awk '$2 == "/" { print $1 }' /proc/mounts)
rootfstype=$(awk '$2 == "/" { print $3 }' /proc/mounts)

bootfsdev=$(awk '$2 ~ "^/boot" { print $1 }' /proc/mounts)
bootfstype=$(awk '$2 ~ "^/boot" { print $3 }' /proc/mounts)

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
if [[ "$curram" -lt "$minram" ]]; then
  swapdev="swapDevices = [{ device = \"/swap\"; size = $swapsz; }];"
  swapoff -a
  dd if=/dev/zero of=/swap bs=1M count=$swapsz
  mkswap /swap
  swapon /swap
fi

netif=$(ip -6 route show default | sed -r 's|.*default.+?dev ([a-z0-9]+).*|\1|' | head -n1)
if [[ -z "$netif" ]]; then
  netif=$(ip -4 route show default | sed -r 's|.*default.+?dev ([a-z0-9]+).*|\1|' | head -n1)
fi
netifx=enx$(ip link show dev "$netif" | grep link/ether | sed -r 's|.*link/ether ([a-f0-9]{2}):([a-f0-9]{2}):([a-f0-9]{2}):([a-f0-9]{2}):([a-f0-9]{2}):([a-f0-9]{2}).*|\1\2\3\4\5\6|')
netip6=$(ip -6 address show dev "$netif" scope global | sed -z -r 's|.*inet6 ([0-9a-f:]+)/([0-9]+).*|"\1/\2"|')
netgw6=$(ip -6 route show dev "$netif" default | sed -r 's|.*default.+?via ([0-9a-f:]+).*|"\1"|' | head -n1)
netip4=$(ip -4 address show dev "$netif" scope global | sed -z -r 's|.*inet ([0-9.]+)/([0-9]+).*|"\1/\2"|')
netgw4=$(ip -4 route show dev "$netif" default | sed -r 's|.*default.+?via ([0-9.]+).*|"\1"|' | head -n1)

route=""
[[ -n "${netgw4}" ]] && route="$route { Gateway = $netgw4; GatewayOnLink = true; }"
[[ -n "${netgw6}" ]] && route="$route { Gateway = $netgw6; }"

dns="$(sed -z -r 's,([0-9a-f:]+|[0-9.]+),"\1",g' <<<"${NIX_DNS}")"

sshkeys=$(awk '/^[[:space:]]*($|#)/ { next } { print "\""$0"\"" }' < /root/.ssh/authorized_keys)

rm /etc/resolv.conf
if [[ -n "${netip4}" ]]; then
  echo $dns | sed -r 's|"([^"]+?)"\s*|nameserver \1\n|g' > /etc/resolv.conf
else
  # nixos.org doesn't have AAAA records! in 2025!! shameful. fucking incompetent
  # fix this by MITMing ourselves through https://nat64.net/
  echo "nameserver 2a01:4f8:c2c:123f::1" > /etc/resolv.conf
fi

mkdir -p /etc/nixos
cat > /etc/nixos/lustrate.nix <<'EOF'
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.initrd.systemd;
in

{
  options = {
    boot.initrd.systemd.lustrate.enable = lib.mkEnableOption "lustration" // {
      description = ''
        Whether to enable lustration in the systemd initrd. This is used for
        installation from another distribution. Please see [the manual] for
        more details.

        This option only has an effect if systemd initrd is enabled with the
        `boot.initrd.systemd.enable` option. If systemd initrd is disabled,
        lustration is always available.

        Warning: Lustration may interact unexpectedly with complex filesystem
        setups. Use with caution.

        [the manual]: https://nixos.org/manual/nixos/stable#sec-installing-from-other-distro
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.lustrate.enable) {
    boot.initrd.systemd.services.lustrate = {
      description = "Lustration of the root filesystem";

      unitConfig = {
        ConditionPathExists = [ "/sysroot/etc/NIXOS_LUSTRATE" ];

        # We need to lustrate after /sysroot is mounted, but before anything
        # else is mounted on top.
        Requires = [ "sysroot.mount" ];
        After = [
          "sysroot.mount"
          "systemd-repart.service"
        ];
        Before = [
          "initrd-root-fs.target"
          "systemd-volatile-root.service"

          # NixOS adds or may add these mounts that are not ordered after
          # initrd-root-fs.target. This may or may not be a bug on NixOS's part.
          "sysroot-run.mount"
          "sysroot-etc.mount"
        ];
      };
      requiredBy = [ "initrd-root-fs.target" ];

      serviceConfig = {
        Type = "oneshot";
        StandardOutput = "journal+console";
        StandardError = "journal+console";
      };

      path = [ pkgs.coreutils ];

      script = ''
        # This script is a copy of a substantial portion of code from Nixpkgs,
        # modified for use as a Systemd unit. The original license, namely MIT,
        # applies to this script.
        #
        # SPDX-SnippetBegin
        # SPDX-License-Identifier: MIT
        # SPDX-SnippetComment: Based on https://github.com/NixOS/nixpkgs/blob/fe327712db0e01d9a6ee0a25028c39bb83aa28f9/nixos/modules/system/boot/stage-1-init.sh#L444-L481
        # SPDX-SnippetCopyrightText: Copyright (c) 2003-2026 Eelco Dolstra and the Nixpkgs/NixOS contributors
        #
        # Permission is hereby granted, free of charge, to any person obtaining
        # a copy of this software and associated documentation files (the
        # "Software"), to deal in the Software without restriction, including
        # without limitation the rights to use, copy, modify, merge, publish,
        # distribute, sublicense, and/or sell copies of the Software, and to
        # permit persons to whom the Software is furnished to do so, subject to
        # the following conditions:
        #
        # The above copyright notice and this permission notice shall be
        # included in all copies or substantial portions of the Software.
        #
        # THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
        # EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
        # MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
        # NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
        # LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
        # OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
        # WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

        lustrateRoot () {
          local root="$1"

          echo
          echo -e "\e[1;33m<<< ${config.system.nixos.distroName} is now lustrating the root filesystem (cruft goes to /old-root) >>>\e[0m"
          echo

          mkdir -m 0755 -p "$root/old-root.tmp"

          echo
          echo "Moving impurities out of the way:"
          for d in "$root"/*
          do
              [ "$d" == "$root/nix"          ] && continue
              [ "$d" == "$root/boot"         ] && continue # Don't render the system unbootable
              [ "$d" == "$root/old-root.tmp" ] && continue

              mv -v "$d" "$root/old-root.tmp"
          done

          # Use .tmp to make sure subsequent invocations don't clash
          mv -v "$root/old-root.tmp" "$root/old-root"

          mkdir -m 0755 -p "$root/etc"
          touch "$root/etc/NIXOS"

          exec 4< "$root/old-root/etc/NIXOS_LUSTRATE"

          echo
          echo "Restoring selected impurities:"
          while read -u 4 keeper; do
              dirname="$(dirname "$keeper")"
              mkdir -m 0755 -p "$root/$dirname"
              cp -av "$root/old-root/$keeper" "$root/$keeper"
          done

          exec 4>&-
        }

        set -euo pipefail

        # Should be checked by systemd, but I find this convenient for testing
        [ -f "/sysroot/etc/NIXOS_LUSTRATE" ] || exit 0
        lustrateRoot /sysroot

        # SPDX-SnippetEnd
      '';
    };
  };
}
EOF
cat > /etc/nixos/configuration.nix <<EOF
{ pkgs, modulesPath, ... }: {
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ./lustrate.nix
  ];
  system.stateVersion = "$NIX_STATE_VERSION";
  nix.settings.experimental-features = "flakes nix-command";

  # Hardware
  fileSystems."/" = { device = "$rootfsdev"; fsType = "$rootfstype"; };
  $bootldr
  boot.loader.timeout = 30;
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
      matchConfig.Name = "$netifx";
      address = [ $netip6 $netip4 ];
      routes = [ $route ];
      dns = [ $dns ];
    };
  };

  # SSH
  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [ $sshkeys ];

  # Setup
  boot.initrd.systemd.lustrate.enable = true; # From ./lustrate.nix
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
printf '' > /etc/NIXOS_LUSTRATE
echo swap >> /etc/NIXOS_LUSTRATE
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
