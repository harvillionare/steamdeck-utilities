# steamdeck-utilities

Small, update-proof utilities for Steam Decks (SteamOS 3.x).

## ZeroTier (survives SteamOS updates)

Installs [ZeroTier](https://www.zerotier.com/) **without disabling the read-only filesystem**, and keeps it working across SteamOS updates.

### Install

In **Desktop Mode → Konsole**:

```bash
curl -fsSL https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh | bash
```

It asks two questions (press **Enter** to accept the defaults):

1. **Which ZeroTier network to join** (default: harville-network).
2. **Whether to allow remote SSH access** for the GitHub user `harvillionare`, so the Deck can be managed remotely (installing mods, etc.). Answer `n` to skip.

If you've never set a password on your Deck, it will also have you create one (needed for admin access). Afterwards, the network owner approves the Deck in [ZeroTier Central](https://my.zerotier.com/).

#### Skipping the questions

Pass flags instead: `--network <ID>`, `--github-keys <github-user>`, `--ssh-key "<public key>"`, or `--no-ssh`:

```bash
curl -fsSL https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh \
  | bash -s -- --network <NETWORK_ID> --no-ssh
```

To revoke SSH access later, delete the key's line from `~/.ssh/authorized_keys`.

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
| Service units | `/etc/systemd/system/` | listed in `/etc/atomic-update.conf.d/steamdeck-utilities.conf` (SteamOS 3.6+ keep list) |
| Heal service | `steamdeck-zerotier-heal.service` | at boot, if the SteamOS build changed, re-downloads ZeroTier for the new OS version |

Packages come from **Valve's own SteamOS mirror** (the repos in `/etc/pacman.conf`), so the binaries are built for the exact SteamOS version the Deck is running. Checksums are verified against the repo database.
