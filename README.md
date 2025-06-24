# Mastodon + Bluesky Cross-Posting Fork

This is a fork of [Mastodon](https://github.com/mastodon/mastodon) that adds automatic cross-posting to Bluesky's ATProtocol network.

## Features

**All original Mastodon features**

- This fork maintains full compatibility with upstream Mastodon while adding:

**Automatic Bluesky Cross-Posting**

- Posts from Mastodon automatically appear on Bluesky
- Cross-posts public statuses (excludes replies and boosts)
- Supports text, media, links and mentions
- Status deletions on Mastodon remove posts from Bluesky
- Per-user settings to enable/disable cross-posting
- Mastodon profile (display name, bio, profile picture and banner) syncs with Bluesky

**Unified Installation**

- One-command setup for both Mastodon and Bluesky PDS (Personal Data Server)
- Combined Docker environment
- Automatic SSL certificate management via Caddy

## Quick Installation

Run the combined installer as root on a fresh Ubuntu/Debian server:

```bash
curl https://raw.githubusercontent.com/msonnb/mastodon/main/dist/installer.sh > installer.sh
sudo bash installer.sh
```

**Requirements:**

- Fresh Ubuntu 20/22 or Debian 11/12 server
- Domain name(s) with DNS pointing to your server:
  - Can use the same domain for both services (e.g., `example.social`) to keep your handle consistent
    - Mastodon: `@alice@example.social` / Bluesky: `@alice.example.social`
  - Or separate (sub)domains: Mastodon (e.g., `example.social`) + Bluesky PDS (e.g., `pds.example.social`)
    - Mastodon: `alice@example.social` / Bluesky: `@alice.pds.example.social`
- SMTP server credentials for email notifications
- Ports 80 and 443 accessible from the internet

The installer will:

1. Install Docker and system dependencies
2. Set up Bluesky Personal Data Server
3. Set up Mastodon with cross-posting enabled
4. Configure automatic SSL certificates
5. Create systemd services for both platforms

## Post-Installation Setup

1. **Log in to Mastodon**: Use the admin credentials provided by the installer
2. **Enable Cross-Posting**: In Mastodon settings, go to "Account > Bluesky Cross-Posting" and enable it
   - A Bluesky account is automatically created for you when enabled
   - Your Bluesky handle will match your Mastodon username

## Cross-Posting Behavior

- ✅ **Cross-posted**: Public posts with text and/or images
- ❌ **Not cross-posted**: Replies, boosts/reblogs, private/unlisted posts, polls

## Navigation

- [Original Mastodon Repository](https://github.com/mastodon/mastodon)
- [Mastodon Documentation](https://docs.joinmastodon.org)
- [Bluesky ATProtocol](https://atproto.com)

## Contributing

This fork tracks upstream Mastodon releases. Bluesky-specific improvements welcome via pull requests.

## License

Licensed under GNU Affero General Public License v3.0 - see [LICENSE](LICENSE) file.
