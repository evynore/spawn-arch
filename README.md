# spawn-arch

`spawn-arch` is a narrowly scoped, auditable installer for one machine profile: an
Intel + NVIDIA Optimus laptop with KDE Plasma, LUKS2, Btrfs, systemd-boot, and
zram. Its balanced workstation baseline also pins PipeWire, a user-scoped
OpenSSH agent, a local Docker daemon, a closed inbound firewall, bounded
persistent logs, package vulnerability auditing, and low-risk kernel hardening.
It is intentionally fail-closed around disk identity and boot state.

This repository is not a generic distribution installer. Read the generated plan
before authorizing the destructive step.

## Installation from the official Arch ISO

Boot the current official Arch Linux ISO in UEFI mode. The live environment runs
as root.

1. Connect to the network. For Wi-Fi, use `iwctl`; for wired Ethernet, verify the
   link with `ip link` and test connectivity with `ping -c 3 archlinux.org`.
2. Confirm that the clock is synchronized:

   ```console
   timedatectl status
   ```

3. Download the fixed v0.1.0 release archive and its checksum. Do not substitute a
   branch archive or execute downloaded text through a shell pipeline.

   ```console
   curl --fail --location --remote-name https://github.com/evynore/spawn-arch/releases/download/v0.1.0/spawn-arch-v0.1.0.tar.gz
   curl --fail --location --remote-name https://github.com/evynore/spawn-arch/releases/download/v0.1.0/spawn-arch-v0.1.0.tar.gz.sha256
   sha256sum -c spawn-arch-v0.1.0.tar.gz.sha256
   tar -xzf spawn-arch-v0.1.0.tar.gz
   cd spawn-arch-v0.1.0
   ```

4. Run the read-only environment and hardware checks:

   ```console
   ./spawn-arch doctor
   ```

5. Build the non-destructive installation plan. Select only the intended Linux
   target SSD and answer the profile prompts:

   ```console
   ./spawn-arch plan
   ```

6. Review `/run/spawn-arch/plan.json` in full. In particular, compare the target
   device, model, serial, WWN, capacity, partition geometry, username, hostname,
   and source commit with the hardware and the release you downloaded.
7. Start the destructive phase only after that review:

   ```console
   ./spawn-arch install
   ```

   The installer re-resolves the target from stable identity immediately before
   writing. Its confirmation is the exact target serial from the plan, entered in
   this form:

   ```text
   ERASE <serial-from-plan>
   ```

   It then asks separately for the encryption secret and the user password. These
   secrets are held in the live runtime only and are removed during cleanup.

8. When installation completes, verify the mounted target without modifying it:

   ```console
   ./spawn-arch verify /mnt
   ```

   If installation or verification reports a failure, **Do not reboot**. After a
   post-install finalization failure, the only safe continuation is:

   ```console
   ./spawn-arch install --resume-finalize
   ./spawn-arch verify /mnt
   ```

   The resume path verifies the recorded disk and filesystem fingerprints and
   never invokes the partitioner or Archinstall again. For any other failure,
   preserve the complete output and inspect the target from the live ISO. Before
   rebooting, create a local read-only diagnostic report in the current directory:

   ```console
   ./spawn-arch investigate
   ```

   The command prints paths for two bounded, redacted reports: a readable `.txt`
   report for paging or photographing and a canonical `.json` report for machine
   analysis. Open the readable report from the same directory with:

   ```console
   less spawn-arch-investigation-*.txt
   ```

   The reports contain installer state, log tails, mounts, active LUKS status,
   relevant processes, systemd machine state, hardware inventory, tool versions,
   and a `dmesg` tail. The command never reads credential files, changes the
   target, or uploads either report.

9. Only after the offline verification succeeds, reboot:

   ```console
   systemctl reboot
   ```

10. Select the new Linux disk in the firmware if necessary. Enter the `LUKS passphrase`
    when prompted, then sign in to the `Plasma Wayland` session.
11. Run the physical acceptance checks below. If every required check succeeds,
    commit this boot as the known-good state:

    ```console
    sudo spawn-arch verify --bless
    ```

Do not bless an unverified boot. A successful bless is an explicit acceptance of
the running kernel, root subvolume, graphics paths, services, power profile, and
boot artifacts.

## Storage and boot model

The root filesystem is encrypted with LUKS2. Inside it, Btrfs provides separate
`@`, `@home`, `@log`, `@pkg`, and `@snapshots` subvolumes. Zram supplies compressed
swap; no disk swap partition is created. The EFI System Partition remains outside
the encrypted container so firmware can start the boot chain.

Systemd-boot launches unified kernel images named `spawn-arch-current.efi` and
`spawn-arch-last-good.efi`. The current entry uses the dynamic Btrfs default
subvolume rather than embedding `subvol=` in the kernel command line. This is what
allows a rollback to perform a transactional default-subvolume transition.

The last-good entry is a kernel/initramfs recovery path: last-good does not switch the Btrfs root. Use the rollback command when the filesystem state must move to a
snapshot as well.

## Trust boundary

The root filesystem is encrypted with LUKS2, but ESP, systemd-boot, UKIs, and boot-state JSON are unencrypted and unsigned. Therefore physical write access to the ESP can modify the boot chain. Secure Boot and TPM enrollment are deliberately
left for a later, separately designed trust model; this release makes no verified
boot claim.

Disk selection is fail-closed. The installer excludes the live medium, mounted
disks, read-only devices, and disks with Windows markers; it revalidates immutable
identity before each destructive boundary. With a dedicated Linux SSD selected,
the installer never mounts or writes the Windows SSD and it does not create or
modify a Windows boot entry. Use the firmware boot menu until the explicit
post-install synchronization below is requested.

No software can compensate for selecting the wrong physical disk. The plan review
and exact serial confirmation remain mandatory operator controls.

## Balanced workstation baseline

The encrypted-root prompt uses the official Breeze Plymouth theme at 2x scale.
Plymouth is embedded into the UKI initramfs before `sd-encrypt`, while `quiet
splash` keeps normal boot output behind the graphical prompt. Press Escape to
show boot diagnostics. Before Secure Boot is enabled, the systemd-boot editor is
available with `e`; append `plymouth.enable=0 disablehooks=plymouth` for a
one-time text-mode recovery boot if the graphical prompt ever fails.

PipeWire, PipeWire Pulse compatibility, ALSA integration, and WirePlumber are
installed explicitly rather than inherited accidentally through Plasma. `rtkit`
provides the realtime scheduling policy expected by the audio stack, and
`wireless-regdb` supplies the kernel regulatory database. The
OpenSSH agent is enabled as a systemd user service and uses
`$XDG_RUNTIME_DIR/ssh-agent.socket`; the SSH server remains disabled. Keys are
never generated, copied, enumerated, or unlocked by the installer. OpenSSH uses
`AddKeysToAgent yes`, and `ksshaskpass` can store an encrypted key's passphrase
in KWallet only after the first use, when the user explicitly selects `Remember password`
in the dialog. The private key remains a normal mode-0600 file under
`~/.ssh`; KWallet stores only the remembered passphrase.

Automatic reuse requires KWallet to be unlocked by a password-based Plasma login
using the same password as the default wallet. Autologin, passwordless login,
and fingerprint-only login do not provide that secret and are outside
this guarantee. An empty agent is valid until a key is actually used; the
installer never runs `ssh-add` eagerly.

The created user's login shell is Zsh. `/etc/zsh/zshrc` initializes native Zsh
completions and Starship from the managed `/etc/starship.toml`, which is pinned
to Starship's official `plain-text-symbols` preset. User customization remains
available through `~/.zshrc`, `~/.zshenv`, and user environment.d files; the
installer creates none of those user files. FiraCode Nerd Font Mono is installed
and selectable, but it is not selected automatically in Konsole, Plasma,
editors, or global font configuration.

Docker runs as a local system service with its Unix socket only. Container logs
use the bounded `local` driver, and new containers inherit the daemon's
no-new-privileges policy. The installer does not add the interactive user to the
`docker` group because access to that socket is root-equivalent; use `sudo
docker` until that privilege is explicitly accepted. Docker's TCP API is not
configured. Its unit wants and starts after both `network-online.target` and
`firewalld.service`, avoiding the startup race between Docker rule management and
firewalld initialization.

Firewalld uses the `spawn-workstation` default zone. It drops unsolicited inbound
traffic and opens no services or ports. Network sharing, KDE Connect, SSH access,
game streaming, and published container ports require explicit operator action.
Docker manages separate forwarding rules, so publishing a container port is a
network exposure decision and is not constrained by the workstation zone alone.
Persistent journald storage is compressed, limited to 1 GiB while reserving 2
GiB free, and retained for at most 30 days. `arch-audit.timer` provides package
vulnerability checks; upgrades remain manual full-system upgrades rather than
unattended or partial updates.

The unused `systemd-pcrlogin` measurement unit is conditionally disabled because
this release does not enroll TPM-backed login or disk-unlock policy. The TPM is
never cleared or re-provisioned by spawn-arch.

This baseline deliberately excludes alternative initramfs tooling, mandatory
access-control policy, audit rules, signed-boot enrollment, GPU compute and
container toolchains, and game packages. Those change the boot or application
trust model and require separate design and acceptance work.

## Status, snapshots, and recovery

Run installed-state commands as root:

```console
sudo spawn-arch status
sudo spawn-arch snapshots list
sudo spawn-arch verify
```

### Add Windows to systemd-boot explicitly

After booting the installed system, copy Windows Boot Manager to the Linux ESP:

```console
sudo spawn-arch windows-boot sync
```

The command discovers a different GPT/vfat ESP containing both
`EFI/Microsoft/Boot/bootmgfw.efi` and its BCD database. It mounts that source
read-only, never mounts the Windows data partition, copies the complete
`EFI/Microsoft` tree through a validated staging directory, and adds an explicit
systemd-boot entry. Re-running the command after a Windows bootloader update is
safe; an unchanged tree reports `already up to date`.

If more than one valid Windows ESP exists, inspect `lsblk -f` and select the
partition explicitly:

```console
sudo spawn-arch windows-boot sync --source /dev/nvme0n1p1
```

The copied EFI files remain byte-identical so their Microsoft signatures are
preserved. Secure Boot is still disabled in this release; a later design must
sign the Linux boot chain and enroll the applicable Microsoft UEFI CA before it
can make a verified-boot claim.

To prepare a transactional rollback, select either the current known recovery
point or an explicit Snapper snapshot:

```console
sudo spawn-arch rollback latest
sudo spawn-arch rollback 7394
```

Rollback creates a read-only safety snapshot, makes a writable future root,
builds and validates its UKI, and commits boot state with crash-recovery metadata.
Reboot into it, run the acceptance checks, and only then use:

```console
sudo spawn-arch verify --bless
```

If the current UKI cannot boot but the filesystem default should remain unchanged,
select the last-good entry from systemd-boot or request it from a working console:

```console
sudo bootctl set-oneshot spawn-arch-last-good
systemctl reboot
```

## GU606AX physical acceptance gate

Run these checks after the first graphical login and after every rollback. Capture
their output before blessing:

```console
uname -a
bootctl status
cat /proc/cmdline
findmnt --verify
findmnt -no SOURCE,FSTYPE,OPTIONS /
btrfs subvolume get-default /
swapon --show
powerprofilesctl get
loginctl show-session "$XDG_SESSION_ID" -p Type -p Desktop
glxinfo -B
vulkaninfo --summary
prime-run glxinfo -B
nvidia-smi
systemctl --user is-active pipewire pipewire-pulse wireplumber ssh-agent
ssh-add -l
sudo docker info
sudo firewall-cmd --get-default-zone
sudo firewall-cmd --get-log-denied
sudo firewall-cmd --zone=spawn-workstation --list-all
sudo journalctl --verify
sudo journalctl --disk-usage
systemctl is-active arch-audit.timer
systemctl --failed
journalctl -b -p warning
```

Acceptance requires all of the following:

- The selected entry and command line belong to the current unified kernel image.
- The active Btrfs root is the filesystem default, and mount verification is clean.
- zram is the only swap and has priority 100.
- The session is a non-root local Plasma Wayland session.
- Intel is the default renderer for OpenGL and Vulkan.
- NVIDIA works through PRIME offload, and `nvidia-smi` is healthy.
- The initial power profile is `balanced` and required services are active.
- PipeWire and the user SSH agent are active; an empty `ssh-add -l` result is valid.
- Docker is local and responsive, and the closed firewalld zone has no implicit openings.
- Persistent journal verification succeeds and the package audit timer is active.
- There are no unexplained failed units or boot warnings.

Do not bless the boot if any required observation fails. Diagnose it while the
previous known-good UKI and snapshot state are still preserved.

## Development verification and releases

The normal local gate is:

```console
make quality
```

The destructive lifecycle harness operates only on disposable QEMU disk images;
it never accepts a host block device. A developer with the required virtualization
tools and an independently verified Arch ISO can run:

```console
export SPAWN_QEMU_ISO=/path/to/archlinux.iso
export SPAWN_QEMU_ISO_SHA256=<sha256-from-archlinux.org>
make integration
```

Release archives are built only from a clean tree with an annotated SemVer tag at
`HEAD`:

```console
scripts/build-release-archive.sh v0.1.0
```

The builder produces a deterministic archive, checksum, installation note, and a
`SOURCE_COMMIT` provenance file under `dist/`. Tag creation and publication are
explicit maintainer actions after automated gates and physical acceptance pass.
