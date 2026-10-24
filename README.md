# Media Server

🇬🇧 English | [🇮🇹 Italiano](README.it.md)

Your own "private Netflix": a home server that downloads movies and TV shows and lets you watch them on Plex, with a page to search and request titles without knowing anything about computers.

## How to use it (no technical skills required)

Whoever set up the server (see the "Installation" section below) will give you two addresses to bookmark in your browser. You can use `mediaserver.local` instead of the IP (easier to remember, and it never changes) — it works out of the box on Mac/iPhone/Android/Linux; on some Windows PCs it might not work, in which case use the IP shown during installation:

- **The main page** (e.g. `http://mediaserver.local/` or `http://192.168.1.50/`): from there you open the dashboard with the status of all services. It will ask for a username and password — the ones set during installation.
- **The page to request movies/shows** (Overseerr, e.g. `http://mediaserver.local:5055/` or `http://192.168.1.50:5055/`): search for a title, click "request", and the server starts downloading it on its own. Log in with your Plex account.

To **watch** what you requested, open the Plex app (on TV, phone, computer) and log in with your plex.tv account — as soon as the download and file organization are done, the title appears in the library.

Subtitles (Italian and English) are downloaded and synced automatically, no need to look for them by hand.

If you're not on the same home Wi-Fi network (you're out), you need the **Tailscale** app installed and signed in with the same account used on the server: without it, the addresses above won't open from outside home.

If an address stops working, ask whoever set up the server: the router probably changed the machine's address.

---

## Installation (for whoever manages the server)

The following sections are for whoever configures and maintains the server (requires SSH/terminal access to the machine).

### Requirements

- A dedicated computer (not your everyday PC) with Debian/Ubuntu Server, even headless
- Intel GPU with Quick Sync (recommended but not required: speeds up Plex's video conversion, "transcoding" — without it, Plex uses the CPU)
- One or more USB disks (even different brands/sizes) to store movies and shows
- SSH and `sudo` access on the machine (admin account)

### Running the installation

```bash
git clone <this-repo-url>
cd media-stack-setup
sudo bash setup.sh
```

The script (`setup.sh`) does everything on its own: prepares the disks, installs Docker (the program that runs each service in its own isolated "container") and connects the various services to each other. It can be re-run as many times as you want — it skips steps already done, which is useful if it gets interrupted or if you add a disk later.

During execution it asks:
- how many disks to use for the movie library
- whether to use a separate disk for config/downloads or a folder on the first disk
- username/password for server access (applies to the dashboard, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent)
- whether to also install Radarr/Sonarr/Prowlarr/Bazarr/FlareSolverr (the programs that search for and organize downloads — see below what each one does)
- Plex claim token (optional, to link the Plex account right away)
- whether to install Tailscale (for access from outside home)

At the end it prints a summary with all the addresses and passwords to hand over to whoever will use the server.

### Server address

The script sets the machine's hostname to `mediaserver` and installs `avahi-daemon` (mDNS), so the server is reachable as `http://mediaserver.local/` from any device on the same network that supports mDNS (Mac, iPhone, Android, Linux out of the box; on Windows you sometimes need to install Bonjour, or it won't work). It always works, even if the router changes the machine's IP.

The final summary from `setup.sh` also shows the direct IP (e.g. `http://192.168.1.50/`) as an alternative/fallback. If you'd rather use only that, it can change in the future: in that case re-run `sudo bash setup.sh` to read the new IP, or reserve a fixed IP for the server from the router's panel ("DHCP reservation"/"static IP").

For access from outside home, Tailscale (if installed) creates a second IP valid anywhere, shown in the same summary.

### What each service does

- **Plex**: where you watch movies and shows.
- **Overseerr**: where you search for and request new titles (meant for viewers, not admins).
- **Radarr / Sonarr**: receive the requests and search for the file to download, one for movies and one for shows.
- **Prowlarr**: the search engine shared by Radarr and Sonarr (the "indexers", i.e. the sources to search, are configured here once).
- **Bazarr**: searches for and syncs subtitles for what Radarr/Sonarr have downloaded.
- **qBittorrent**: actually downloads the files.
- **FlareSolverr**: only needed for indexers protected by Cloudflare (e.g. 1337x) — helps Prowlarr get past that protection.
- **Dashboard**: the landing page with the status of all these services.

### Project structure

```
setup.sh                   orchestrator: disks, Docker, copies the files below to /opt/mediaserver
docker-compose.yml         service definitions
nginx/default.conf         reverse proxy + single login (HTTP Basic)
dashboard/index.html       page showing service status
qbittorrent/               qBittorrent initial config (saved only on first boot)
add-mac-key.sh             adds an SSH public key to the current user
```

All *live* service configs (API keys, Plex token, password hashes) stay
only on the server under `/opt/mediaserver/data/docker/`, never in this repo:
never commit that folder or the `.env`/`.env.credentials` files.

### Login

There is **a single login** for everything that goes through the nginx reverse proxy (dashboard, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent via `/qbittorrent/`): the credentials are set on first run and saved in `/opt/mediaserver/.env.credentials` on the machine.

**Plex stays separate**: it uses your plex.tv account, not the reverse proxy login — by design, since it's tied to your real Plex identity.

qBittorrent accepts connections without a password only if they come from the reverse proxy (same Docker network); if you open its direct port (`:8080`) it still asks for its own credentials.

### Multiple disks for the movie library

If you add a disk in the future (e.g. a bigger HDD), re-run `sudo bash setup.sh`: the script recognizes disks already mounted and only asks you to format the new one. Additional disks are mounted at `/mnt/media2`, `/mnt/media3`, etc., and automatically connected to the containers via `docker-compose.override.yml` (generated automatically, don't edit it by hand).

In Plex, afterwards, add `/movies2`, `/movies3`... as extra folders of the same "Movies" library — files on the extra disks work the same way, just add the folder.

### Transcoding

The script passes `/dev/dri` to the Plex container for Intel Quick Sync, if present on the hardware. Hardware transcoding is however a **Plex Pass** feature: without an active subscription on the linked plex.tv account, the "Use hardware acceleration when available" option doesn't even show up in settings. Without Plex Pass, Plex does software transcoding on the CPU — if your hardware is modest, it's worth setting in Plex:
- **Transcoder quality = Automatic** (not "Make my CPU hurt", which forces maximum quality even when the CPU can't keep up in real time)
- **Max simultaneous transcodes** = a low number (2 on an 8-thread CPU is a good starting point)
- **Transcoder temp directory** on a tmpfs (RAM) if you have memory to spare, to avoid wearing out the SSD with writes

### Public indexers and quality profiles, ready to go

If Prowlarr doesn't have any indexer configured yet, the script adds a starter set (1337x, The Pirate Bay, LimeTorrents, YTS, EZTV) — all public, no account/credentials required. You can add others (even private ones, with your own credentials) at any time from Prowlarr, this is just a starting point.

It also creates 4 quality profiles on Radarr and Sonarr — **ITA 4K**, **ITA Full HD**, **ENG 4K**, **ENG Full HD** — based on the language detected in the release title (not text tags: it uses Sonarr/Radarr's native parser), so you can assign each movie/show the resolution+language combo you want.

### Indexers protected by Cloudflare (e.g. 1337x)

FlareSolverr is already configured as an Indexer Proxy in Prowlarr with the `flaresolverr` tag. When you add an indexer that requires FlareSolverr (Prowlarr flags this on the indexer's page), you need to assign it the same `flaresolverr` tag in "Add Indexer" — without that shared tag, Prowlarr won't route requests through the proxy even though it's configured.

### Subtitles (Bazarr)

Bazarr is connected to Radarr and Sonarr and searches for subtitles in **Italian and English for every movie/episode** (language profile `ita`, with no "cutoff": unlike the default behavior, it doesn't stop at the first language found, it always downloads both). You need a subtitle provider configured under Settings > Providers (e.g. OpenSubtitles.com, free account).

**Automatic sync**: every downloaded subtitle is automatically re-synced to the video's audio (`ffsubsync`, Settings > Subtitles > "Use Subsync") — useful when the provider only finds a text match and not an exact file hash. For a subtitle downloaded before this option existed, it needs to be synced by hand once (movie/episode page in Bazarr > sync icon on the subtitle).

### Requesting movies/shows (Overseerr)

Overseerr (`http://<IP>:5055/`) is a search/request interface: viewers search for a title in the TMDB catalog (with filters for genre, studio, year, rating, plus "trending"/"upcoming" carousels), request it with one click, and Overseerr automatically sends it to Radarr/Sonarr — without giving direct access to Radarr/Sonarr to people who shouldn't manage their configuration.

**Doesn't go through the nginx reverse proxy** (direct port 5055, no single login): unlike Radarr/Sonarr/Prowlarr/Bazarr, Overseerr doesn't support running under a sub-path behind a reverse proxy because of how Next.js handles assets. First access: setup wizard in the browser, log in with the Plex account (same account as the Plex server), then connect Radarr/Sonarr (Settings > Services) using the API keys found in their respective `config.xml`.

### Hardlinks, not copies

Radarr and Sonarr are configured to use hardlinks instead of copying files during import: the file downloaded by qBittorrent and the one in the organized library folder are the same data on disk (no doubled space), as long as downloads and the library are on the same disk. If you add a second disk and download something meant to end up there, make sure the download category/folder used by qBittorrent is on the same destination disk, otherwise Radarr/Sonarr will copy instead of linking.

### Reliability

- **Docker's `live-restore`**: if the Docker daemon restarts (update, crash, manual command), containers stay running instead of stopping and waiting for a manual `docker compose up -d`.
- **No swap on external disks**: if a USB disk disconnects while the kernel has memory pages on it, the system can hang. Swap stays only on the system disk.
- **Config on the system disk, not the external one**: Plex/Radarr/Sonarr/qBittorrent config lives on `/opt/mediaserver/data` (internal disk), not on a removable drive — if that disconnects, you only lose access to the movie library (re-downloadable), not the config/history of the whole stack.
