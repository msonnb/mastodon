# Mastodon with Bluesky Cross-Posting

This is a fork of [Mastodon](https://github.com/mastodon/mastodon) that adds automatic cross-posting to Bluesky's ATProtocol network.

## The Problem

In recent years, the decentralized social media landscape has evolved with the emergence of Bluesky alongside the established Mastodon network. While both platforms embrace decentralization - Mastodon through ActivityPub protocol in the fediverse, and Bluesky through its newer ATProtocol - they operate on distinct and incompatible networks that cannot natively communicate with each other. This has led to fragmentation of users between these decentralized platforms which creates several challenges for users:

- **Platform Lock-in**: Users must choose between networks, potentially missing connections and conversations happening on the other platform
- **Manual Cross-posting**: Maintaining presence on both networks requires tedious manual posting to each platform separately
- **Content Duplication**: Without automation, users often abandon one platform or post inconsistently across platforms
- **Network Effect Loss**: Social networks become less valuable when friend groups are scattered across incompatible platforms
- **Handle Consistency**: While third-party bridging solutions exist, they require using different handles on each platform, fragmenting your identity

This fork solves these problems by enabling seamless, automatic cross-posting between Mastodon and Bluesky, allowing users to maintain a unified social media presence across both decentralized networks without manual effort. Unlike bridging solutions, it allows you to use the same handle on both platforms.

## Features

**All original Mastodon features**

- This fork maintains full compatibility with upstream Mastodon while adding:

**Automatic Bluesky Cross-Posting**

- Posts from Mastodon automatically appear on Bluesky
- Cross-posts public statuses (excludes replies and boosts)
- Supports text, media, links and mentions
- Status deletions on Mastodon remove posts from Bluesky
- Per-user settings to enable/disable cross-posting

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

## Technical Details

### Account creation

Each user can opt-in to Bluesky cross-posting by navigating to
_Account > Bluesky cross-posting_ in the settings. When a user enables the
setting, the User model checks whether the user has already enabled it
before by reading the newly added `bluesky_did` property. If it is empty,
the User model calls the `BlueskyAccountCreationWorker` to create a background
job for creating an account on Bluesky. If a user has enabled the setting before
and therefore has a `bluesky_did` saved to the database, we don't need to create
a new account and only set `bluesky_cross_posting_enabled` to true.

To create an account on Bluesky, the worker calls `Bluesky::CreateAccountService`
which creates an account in three steps. First, it retrieves an invite code from the
Bluesky PDS by calling the `com.atproto.server.createInviteCode` endpoint with
the PDS domain and PDS admin password which we need to supply with environment
variables. Second, we can create an account using the
`com.atproto.server.createAccount` endpoint by passing the invite code, a password which we randomly generate and store encrypted to the database, and the account
handle that we'd like to use. For handles, we reuse the user's username on Mastodon,
such that a user with the handle `@alice@myinstance.social` becomes `alice.myinstance.social` on Bluesky if both Mastodon and the PDS are hosted on `myinstance.social` (which is possible by using the install script). While the previous step
created an account on the ATproto network which we can use for authentication, the
third and last step creates a Bluesky profile by creating a record of type `app.bsky.actor.profile` using the
`com.atproto.repo.createRecord` endpoint and first authenticating by calling the `com.atproto.server.createSession` endpoint with the newly created account credentials. For the Bluesky profile, we copy the display name and account note (bio) and reupload the user's avatar and header (banner) to Bluesky by calling the
`com.atproto.repo.uploadBlob` endpoint which returns a reference to the blob that we then include in the profile record.

After the account creation was successful, we save the account details consisting
of the DID (decentralized identifier), handle and encrypted password to the database. Additionally, we show a link to the user's Bluesky profile on the settings page.

**Note:** For the first few hours, a new account might show `Invalid handle` on Bluesky. This usually disappears after cross-posting a few posts.

### Cross-posting statuses (posts)

When a user posts a status, we determine whether it is eligible for cross-posting
to Bluesky based on the following criteria:

- The user has cross-posting enabled
- The status visibility is set to public
- The status is not a reply or reblog, i.e. a "standalone" status

Only if all of the above criteria are met, we pass the status to the `BlueskyPostWorker` which creates a background job and calls the
`Bluesky::PostService`. This service processes the status, converts it
to a Bluesky post and creates the post record on the PDS by performing the following steps. First, it authenticates the user against the PDS and obtains an access token
which is used for all further requests. Next, it converts a Mastodon status into a Bluesky post in three steps:

1. **Truncating text:** Since Bluesky currently has a limit of 300 characters per post, we truncate the status text and insert an ellipsis at the end. Currently, we don't link back to the original post on Mastodon which would be an opportunity for future improvement.
2. **Facet extraction:** Bluesky posts have support for "facets", which describe certain parts of the post text (given by byte start and end positions) that contain some special meaning, like hyperlinks. We use the `app.bsky.richtext.facet#link` facet to add links to web URLs and Mastodon profiles that are mentioned in the post.
3. **Media attachments:** Bluesky posts, like Mastodon statuses, can include media attachments that are embedded in the post. For that, we loop over all media attachments of the status, retrieve the files and reupload them to the `com.atproto.repo.uploadBlob` endpoints like before. To embed them in the post, we include the returned references with a subrecord of type `app.bsky.embed.images` for up to 4 images or `app.bsky.embed.video` for a video. Each embed additionally contains an alt text and optionally the media dimension which we include if they are available in the metadata. Note that not all media formats are allowed by Bluesky. For example, Bluesky only allows `video/mp4` videos, while Mastodon also supports other formats. Currently, we silently skip unsupported formats in order to cross-post as much as possible. In the future, we could either notify the user or even convert the media into a supported format.

Finally, we send the constructed post record to the `com.atproto.repo.createRecord` endpoint which returns the post's URI. We save this URI to the database and show a link called "View on Bluesky" to the status' context menu in the Mastodon UI. Using this URI, we can also delete posts on Bluesky when they are deleted on Mastodon, which we do by calling `com.atproto.repo.deleteRecord` inside another background job.

### Install script

The combined installer script automates the deployment of both Bluesky PDS and Mastodon services on a fresh server through a multi-stage process. The first part installs the Bluesky PDS and is mostly taken from the official install script available here: https://github.com/bluesky-social/pds/blob/3e82147ab1e649d403cd3065ebb500139c7708a2/installer.sh. The only modification is in the `Caddyfile` that configures the Caddy web server. Instead of handling all incoming requests, we only forward the Bluesky related ones to the PDS, all other ones are forwarded to `localhost:8080`, where we will later configure NGINX to handle all Mastodon traffic.

These are the relevant request paths that are handled by the PDS:

- `/xrpc/*`
- `/oauth/*`
- `/.well-known/oauth-protected-resource`
- `/.well-known/oauth-authorization-server`
- `/.well-known/atproto-did`
- `/@atproto/*`
- `/gate`
- all requests to subdomains

The second part installs Mastodon for which it creates a dedicated system user for security isolation and prompts for essential configuration details including admin credentials, domain settings, and SMTP configuration for email delivery. The script downloads the customized docker-compose configuration and generates cryptographic secrets for Rails encryption. It automatically creates the production environment file with all required variables, including the PDS domain and admin password that enable cross-posting functionality. The database setup phase runs Rails migrations to initialize the Mastodon schema, followed by the creation of the admin user with appropriate permissions.

The final configuration phase establishes systemd services for both applications to ensure automatic startup and proper process management. Finally, the installer concludes by providing access information, administrative commands, and network configuration requirements to complete the deployment.

## Navigation

- [Deployed demo instance: bluesync.social](https://bluesync.social)
- [Original Mastodon Repository](https://github.com/mastodon/mastodon)
- [Mastodon Documentation](https://docs.joinmastodon.org)
- [Bluesky ATProtocol](https://atproto.com)

## Contributing

This fork tracks upstream Mastodon releases. Bluesky-specific improvements welcome via pull requests.

## License

Licensed under GNU Affero General Public License v3.0 - see [LICENSE](LICENSE) file.
