# Debian First Network Kit

[中文说明](README.md)

A conservative first-network, official APT source, and SSH bootstrap kit for Debian 12 (bookworm) and Debian 13 (trixie).

The scripts default to Chinese. Select English with `--lang en`.

## Quick start

Copy this repository to a USB drive, log in locally on the Debian server, mount the USB data partition, and run:

```bash
lsblk -f
sudo mkdir -p /mnt/usb
sudo mount /dev/sdX1 /mnt/usb
cd /mnt/usb/debian-first-network-kit
sudo bash scripts/diagnose-network.sh --lang en
sudo bash scripts/bootstrap-network.sh --lang en
```

Replace `/dev/sdX1` with the actual USB data partition shown by `lsblk -f`.

For multiple Ethernet ports, specify the intended interface:

```bash
sudo bash scripts/bootstrap-network.sh --lang en --interface enp2s0
```

The bootstrap:

1. validates Debian 12/13;
2. selects one physical wired NIC without guessing across ambiguous links;
3. preserves the active network manager and refuses ownership conflicts;
4. obtains DHCP, repairs DNS, and writes version-matched official Debian deb822 sources;
5. updates the archive keyring and CA certificates;
6. installs and enables OpenSSH Server without editing `sshd_config`.

It creates backups before replacing files, takes a mutation lock, never globally restarts systemd-networkd, and refuses static ifupdown or foreign matching networkd configurations.

## Installer choices

- Prefer Ventoy **Normal mode**.
- Use Ventoy **GRUB2 mode** only if Normal mode fails for that Linux ISO.
- Do not use Memdisk for Debian netinst.
- `Graphical install` changes the installer UI only; deselect all desktop environments in tasksel for a headless server.
- Select `SSH server` and `standard system utilities`.
- For a simple single-disk small server, guided LVM with all files in one partition is the easiest recovery-oriented layout.

Download and verification:

- <https://www.debian.org/CD/netinst/>
- <https://www.debian.org/CD/verify>

See the Chinese [installation guide](docs/installation-guide.md) and [troubleshooting guide](docs/troubleshooting.md) for the full procedure.

License: [MIT](LICENSE)
