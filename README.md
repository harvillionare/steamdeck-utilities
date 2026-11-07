# steamdeck-utilities

Small, update-proof utilities for Steam Decks (SteamOS 3.x).

## ZeroTier (survives SteamOS updates)

Installs [ZeroTier](https://www.zerotier.com/) **without disabling the read-only filesystem**, and keeps it working across SteamOS updates.

### Install

In **Desktop Mode → Konsole**:

```bash
curl -fsSL https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh \
  | bash -s -- --network <NETWORK_ID>
```

Then approve the new device in [ZeroTier Central](https://my.zerotier.com/).

If you've never set a password on your Deck, the script will ask you to create one (needed for `sudo`).

#### Optional: allow remote SSH access

To let someone (e.g. a friend helping with mods) SSH into the Deck, add their public key:

```bash
curl -fsSL https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh \
  | bash -s -- --network <NETWORK_ID> --ssh-key "ssh-ed25519 AAAA... name@host"
```

or pull keys from a GitHub account with `--github-keys <github-username>`. SSH is enabled by default; pass `--no-ssh` to skip it.

To revoke access later, delete the key's line from `~/.ssh/authorized_keys`.

#### Stays awake while plugged in

The script sets Game Mode's **Sleep after (plugged in)** to **Never**, so a charging/docked Deck stays reachable (the screen still dims and turns off). Battery sleep is unchanged, and Desktop Mode already never sleeps on AC by default. Steam restarts once for a few seconds while this is applied. Skip it with `--no-keep-awake`.

#### Passwordless sudo

By default the script also lets the `deck` user run admin (`sudo`) commands **without a password**, so remote maintenance (installing mods/tools, restarting, updates) doesn't need someone to type the Deck password. Combined with SSH access, **this gives whoever holds the SSH key full control of the Deck.** Only run it with keys you trust.

- Skip it: add `--no-passwordless-sudo`.
- Remove it later: `sudo rm /etc/sudoers.d/zz-steamdeck-utilities`.

### Other commands

```bash
bash /var/lib/steamdeck-utilities/zerotier-install.sh --status       # what's installed + ZeroTier status
sudo bash /var/lib/steamdeck-utilities/zerotier-install.sh --refresh # force a rebuild
sudo bash /var/lib/steamdeck-utilities/zerotier-install.sh --uninstall [--purge]
```

### How it works

| Piece | Where | Why it survives updates |
| :--- | :--- | :--- |
| ZeroTier binaries | `/var/lib/extensions/zerotier-one` ([systemd-sysext](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html)), overlaid onto `/usr` at boot | `/var` is not touched by SteamOS updates |
| ZeroTier identity + network memberships | `/var/lib/zerotier-one` | same; the Deck stays authorized |
| Service units + sudo rule | `/etc/systemd/system/`, `/etc/sudoers.d/` | listed in `/etc/atomic-update.conf.d/steamdeck-utilities.conf` (SteamOS 3.6+ keep list) |
| Heal service | `steamdeck-zerotier-heal.service` | at boot, if the SteamOS build changed, re-downloads ZeroTier for the new OS version |

Packages come from **Valve's own SteamOS mirror** (the repos in `/etc/pacman.conf`), so the binaries are built for the exact SteamOS version the Deck is running. Checksums are verified against the repo database.
