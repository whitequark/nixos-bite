# _nixos-bite_

## Introduction

_nixos-bite_ solves a problem commonly faced by [NixOS] users: commodity VPS providers rarely, if ever offer NixOS installation media, and uploading your own (if available at all) is error-prone and burdensome. This script provides a means to convert a stock [Debian] installation, readily available from any provider, into an up-to-date NixOS installation. It is inspired by [NixOS-Infect], but significantly differs in [scope](#scope) and [implementation](#implementation).

**_nixos-bite_ must *never* be executed on any machine containing valuable data. Only *ever* run it on a freshly installed VPS. The author provides the script AS-IS, WITHOUT ANY WARRANTY, and will not be responsible for any data loss caused by it.**

[NixOS]: https://nixos.org/
[Debian]: https://www.debian.org/
[NixOS-Infect]: https://github.com/elitak/nixos-infect


## Usage

Running _nixos-bite_ preserves essential settings (SSH keys and detected network configuration); once it completes, you should be able to log into the machine using the same credentials as before. There are several ways to invoke it.

If your VPS provider offers [cloud-init], use the following user-data script:

```yaml
#cloud-config
runcmd:
- 'sleep 30s' # wait for network
- 'curl https://codeberg.org/whitequark/nixos-bite/raw/branch/main/nixos-bite.sh | bash -s reboot'
```

If cloud-init is not available or you wish to convert a machine manually, run the following commands on your PC:

```console
$ curl -O https://codeberg.org/whitequark/nixos-bite/raw/branch/main/nixos-bite.sh
$ ssh root@YOUR-MACHINE bash -s reboot < nixos-bite # reboots after installation
$ ssh root@YOUR-MACHINE bash < nixos-bite # allows you to examine the configuration
```

Alternately, run the following commands on your VPS while logged in as `root`:

```console
# curl https://codeberg.org/whitequark/nixos-bite/raw/branch/main/nixos-bite.sh | bash -s reboot
```

[cloud-init]: https://cloudinit.readthedocs.io/


## Compatibility

While _nixos-bite_ isn't tied to a specific provider, differences in environment may cause it to fail. The following configurations are known to have succeeded:

| Date       | Provider      | Configuration            | Source OS             | Target OS         | Result |
| ---------- | ------------- | ------------------------ | --------------------- | ----------------- | ------ |
| 2025-10-05 | [Datalix]     | IPv6 Only, Small, BIOS   | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2025-10-05 | [Datalix]     | IPv6 Only, Small, UEFI   | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2025-10-05 | [Hetzner]     | CPX11 (Intel/AMD)        | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2025-10-05 | [Hetzner]     | CAX11 (Ampere)           | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2025-10-05 | [Vultr]       | vc2-1c-1gb               | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2025-10-05 | [Vultr]       | vc2-1c-0.5gb-v6          | Debian 13 (trixie)    | NixOS 25.05       | ⛔ (not enough RAM) |
| 2025-11-20 | [UpCloud]     | 1/1GB/10GB, IPv6 only    | Debian 13 (trixie)    | NixOS 25.05       | ✅      |
| 2026-01-01 | [Contabo]     | Cloud VPS 20 NVMe, IPv4  | Debian 13 (trixie)    | NixOS 25.11       | ✅      |

If you tried _nixos-bite_ and found it to either succeed or fail on a configuration not listed above, please submit a pull request updating the compatibility table.

[Datalix]: https://datalix.eu/
[Hetzner]: https://hetzner.com/
[Vultr]: https://vultr.com/
[UpCloud]: https://upcloud.com/
[Contabo]: https://contabo.com/


## Options

_nixos-bite_ does not require configuration to do its job: the script examines the environment and takes appropriate action (or fails to do so if the environment differs too much from what it expects). It does, however, accept options that change how the resulting system is configured.

  * The `NIX_CHANNEL` environment variable configures the nixpkgs release channel. Default: `nixos-25.11`.
  * The `NIX_STATE_VERSION` environment variable configures the `system.stateVersion` attribute. Default: extracted from `NIX_CHANNEL` value.
  * The `NIX_SETUP` environment variable accepts a path to an executable (typically, a shell script) that is copied to the installed system and executed once after the first boot. Default: prints a greeting to `tty1`.


## Scope

_nixos-bite_ does not attempt to do everything for everyone; rather, it focuses on performing a group of closely related tasks well. It was designed to:

  * Use Nix channels, not flakes. (If you want to use Nix flakes, use [nixos-anywhere] instead.)
  * Run as `root` only, and take into account credentials for `root` only.
  * Require Debian and rely on APT for installing required tools. (Other OSes may be added at a later point.)
  * Use the disk partitions as-is. (If you want your disk repartitioned, use [nixos-anywhere] instead.)
    * The two recognized partitions are `/` and `/boot` (etc.).
    * The partitions are unconditionally (re)labelled to `root` and `boot`, if possible.
  * (x86 only) Be compatible with both legacy/BIOS and UEFI firmware, with automatic detection.
    * **UEFI:** the [ESP] is wiped, mounted as `/boot`, and populated with `EFI/BOOT/BOOT<arch>.EFI` stub. EFI variables are not modified; the firmware is expected to unconditionally invoke the EFI stub.
    * **BIOS:** the boot partition is not used; `/boot` is placed on the root filesystem and GRUB is installed on the block device for the whole underlying disk.
  * Use hardcoded lists of kernel modules. (This may change in the future.)
  * Use [systemd-networkd] with [predictable interface names][ifnames].
    * The source OS may or may not use predictable interface names; either option is fine.
  * Configure a VPS with a single network interface and static IP configuration.
    * IPv4-only, IPv6-only, and dual stack configurations are all supported.
    * The generated Nix configuration hardcodes the IP address(es) and default route(s) at the point of running the script.
    * DHCP is neither recognized nor configured. (This may change in the future.)
  * Use hardcoded DNS servers; currently [Quad9]. (This may change in the future.)
  * Be (fairly) safe. The diversity of VPS providers is boundless, and edge cases are abound.
    * The default action is to install and configure NixOS, then finish without rebooting. While this is destructive (`/boot` is wiped and repopulated; the bootloader is reconfigured), it keeps the machine accessible so that gross configuration errors may be corrected.
    * Running the script on a previously unknown VPS provider should be an opportunity to explore, not a rush to reimage.
  * Be idempotent.
    * Filesystem is not used for configuration (only environment variables are).
    * Running the script twice produces the same configuration (and erases any changes to its output).

[nixos-anywhere]: https://github.com/nix-community/nixos-anywhere
[systemd-networkd]: https://nixos.wiki/wiki/Systemd-networkd
[ifnames]: https://systemd.io/PREDICTABLE_INTERFACE_NAMES/
[Quad9]: https://quad9.net
[ESP]: https://en.wikipedia.org/wiki/EFI_system_partition


## Implementation

_nixos-bite_ is implemented as a straight line sequence of actions with a minimum of decision points, listed below:

1. Options are validated and reasonable defaults chosen for those that weren't specified.
2. Source OS package manager is used to install required tools.
3. Root (`/`) and boot (`/boot` or its subdirectory) filesystem configuration is extracted. These filesystems are labelled `root` (using `e2label`) and `boot` (using `fatlabel`) correspondingly. Other mountpoints are ignored.
4. Bootloader is configured depending on whether the system uses BIOS or UEFI (indicated by presence of `/sys/firmware/efi`).
5. **For systems with less than 4 GiB of RAM:** Up to 4 GiB of swap is added as a file `/swap` on the root filesystem. Any existing swap partitions are ignored.
6. Host name, IPv4/IPv6 addresses, and default routes are extracted.
7. DNS resolver configuration is replaced with [Quad9].
8. Authorized SSH public keys for user `root` are extracted.
9. NixOS is configured for a typical QEMU guest system, with [systemd-networkd] and [predictable network interface names][ifnames] enabled.
   * Root, boot (for UEFI systems), and swap (for low-RAM systems) mountpoints are configured with the extracted settings.
   * Bootloader is configured for UEFI or legacy firmware (decided by presence of `/sys/firmware/efi`).
   * Any network interface matching `en*` is configured with the extracted settings.
   * User `root` is configured with the extracted SSH public keys.
10. The `NIX_SETUP` script is copied to `/etc/nixos/setup.sh` and made executable. An oneshot systemd service is configured that executes this script and then removes it on successful execution.
11. The `/nix` directory and `nixbldN` users are created, as in [multi-user mode](https://nix.dev/manual/nix/2.28/installation/multi-user.html).
12. The Nix channel `https://nixos.org/channels/$NIX_CHANNEL` is configured with the name `nixos`.
13. [`NIXOS_LUSTRATE`] is configured to preserve `/etc/nixos`, `/etc/resolv.conf`, and the SSH host key.
14. `/boot` is emptied (on both the root and boot filesystems).
    * **For UEFI firmware:** the boot filesystem is then mounted at `/boot`.
    * **For legacy firmware:** the boot filesystem is left unmounted.
15. `switch-to-configuration boot` is used to populate `/boot` and configure the bootloader.
16. The command-line arguments of the script are executed as a new command. (Typically, this will be nothing or `reboot`.)

[`NIXOS_LUSTRATE`]: https://nixos.org/manual/nixos/stable/#sec-installing-from-other-distro


## License

[0-clause BSD](LICENSE.txt). While _nixos-bite_ is a conceptual derivative of [NixOS-Infect], it is not a "derivative work" for licensing purposes.
