# Media Server

Plex + qBittorrent + Radarr/Sonarr/Prowlarr/Bazarr/Overseerr/FlareSolverr, su Docker Compose, con dashboard e reverse proxy nginx davanti a tutto.

## Requisiti

- Macchina x86_64 con Debian/Ubuntu Server (no desktop necessario)
- GPU Intel con Quick Sync (consigliato, non obbligatorio: senza, Plex fa transcoding software)
- Uno o più dischi USB (SSD/HDD, anche di marche/dimensioni diverse) per la libreria film
- Accesso SSH e `sudo` sulla macchina

## Setup

```bash
git clone <url-di-questo-repo>
cd media-stack-setup
sudo bash setup.sh
```

Lo script è rilanciabile: se interrotto o se vuoi aggiungere un disco in più, basta rilanciarlo, salta i passi già fatti.

Durante l'esecuzione chiede:
- quanti dischi usare per la libreria film (anche più di uno, es. un HDD esterno aggiunto in seguito)
- se usare un disco separato per config/download o una cartella del primo disco film
- username/password per l'accesso al server (dashboard + Radarr/Sonarr/Prowlarr/Bazarr/qBittorrent via reverse proxy)
- se installare anche Radarr/Sonarr/Prowlarr/Bazarr/FlareSolverr
- claim token Plex (opzionale, per collegare subito l'account)
- se installare Tailscale (accesso da fuori casa)

## Struttura del progetto

```
setup.sh                   orchestratore: dischi, Docker, copia i file sotto in /opt/mediaserver
docker-compose.yml         definizione dei servizi
nginx/default.conf         reverse proxy + login unico (HTTP Basic)
dashboard/index.html       pagina con lo stato dei servizi
qbittorrent/               config iniziale di qBittorrent (salvata solo al primo avvio)
add-mac-key.sh             aggiunge una chiave pubblica SSH all'utente corrente
```

Tutte le config *live* dei servizi (API key, token Plex, hash password) restano
solo sul server in `/opt/mediaserver/data/docker/`, mai in questo repo: non
committare mai quella cartella o i file `.env`/`.env.credentials`.

## Login

C'è **un solo login** per tutto quello che passa dal reverse proxy nginx (dashboard, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent via `/qbittorrent/`): le credenziali si impostano al primo avvio e vengono salvate in `/opt/mediaserver/.env.credentials` sulla macchina.

**Plex resta separato**: usa il tuo account plex.tv, non il login del reverse proxy — per scelta, dato che è legato alla tua identità Plex vera.

qBittorrent accetta connessioni senza password solo se arrivano dal reverse proxy (stessa rete Docker); se apri la sua porta diretta (`:8080`) ti chiede comunque le sue credenziali.

## Più dischi per la libreria film

Se in futuro aggiungi un disco (es. un HDD più grande), rilancia `sudo bash setup.sh`: lo script riconosce i dischi già montati e ti chiede solo di formattare quello nuovo. I dischi aggiuntivi vengono montati su `/mnt/media2`, `/mnt/media3`, ecc., e collegati automaticamente ai container tramite `docker-compose.override.yml` (generato in automatico, non va editato a mano).

In Plex, dopo, aggiungi `/movies2`, `/movies3`... come cartelle aggiuntive della stessa libreria "Film" — i file sui dischi extra funzionano allo stesso modo, basta aggiungere la cartella.

## Transcoding

Lo script passa `/dev/dri` al container Plex per il Quick Sync Intel, se presente sull'hardware. Il transcoding hardware è però una funzione **Plex Pass**: senza un abbonamento attivo sull'account plex.tv collegato, l'opzione "Use hardware acceleration when available" non compare nemmeno nelle impostazioni. Senza Plex Pass, Plex fa transcoding software sulla CPU — se il tuo hardware è modesto, vale la pena impostare in Plex:
- **Transcoder quality = Automatic** (non "Make my CPU hurt", che forza la massima qualità anche quando la CPU non riesce a starci dietro in tempo reale)
- **Max transcode simultanei** = un numero basso (2 su una CPU a 8 thread è un buon punto di partenza)
- **Transcoder temp directory** su un tmpfs (RAM) se hai margine di memoria, per non consumare scritture sull'SSD

## Indexer pubblici e profili qualità, già pronti

Se Prowlarr non ha ancora nessun indexer configurato, lo script ne aggiunge un set di partenza (1337x, The Pirate Bay, LimeTorrents, YTS, EZTV) — tutti pubblici, nessun account/credenziale richiesta. Puoi aggiungerne altri (anche privati, con le tue credenziali) in qualunque momento da Prowlarr, questo è solo un punto di partenza.

Crea anche 4 profili qualità su Radarr e Sonarr — **ITA 4K**, **ITA Full HD**, **ENG 4K**, **ENG Full HD** — basati sulla lingua rilevata nel titolo della release (non su tag testuali: usa il parser nativo di Sonarr/Radarr), così puoi assegnare a ogni film/serie la combinazione risoluzione+lingua che vuoi.

## Indexer protetti da Cloudflare (es. 1337x)

FlareSolverr è già configurato come Indexer Proxy in Prowlarr con il tag `flaresolverr`. Quando aggiungi un indexer che richiede FlareSolverr (Prowlarr lo segnala nella pagina dell'indexer), devi assegnargli lo stesso tag `flaresolverr` in "Add Indexer" — senza quel tag condiviso, Prowlarr non instrada le richieste tramite il proxy nonostante sia configurato.

## Sottotitoli (Bazarr)

Bazarr è collegato a Radarr e Sonarr e cerca sottotitoli in **italiano e inglese per ogni film/episodio** (profilo lingua `ita`, senza "cutoff": a differenza del comportamento di default, non si ferma alla prima lingua trovata, li scarica sempre entrambi). Serve un provider di sottotitoli configurato in Impostazioni > Provider (es. OpenSubtitles.com, account gratuito).

**Sync automatico**: ogni sottotitolo scaricato viene risincronizzato in automatico sull'audio del video (`ffsubsync`, Impostazioni > Sottotitoli > "Use Subsync") — utile quando il provider trova solo un match testuale e non un hash esatto sul file. Per un sottotitolo già scaricato prima di questa opzione, va risincronizzato a mano una volta (pagina del film/episodio in Bazarr > icona di sync sul sottotitolo).

## Richiesta film/serie (Overseerr)

Overseerr (`http://<IP>:5055/`) è un'interfaccia di ricerca/richiesta: chi guarda cerca un titolo nel catalogo TMDB (con filtri per genere, studio, anno, voto, oltre a caroselli "di tendenza"/"in arrivo"), lo richiede con un click, e Overseerr lo manda in automatico a Radarr/Sonarr — senza dare accesso diretto a Radarr/Sonarr a chi non deve gestirne la configurazione.

**Non passa dal reverse proxy nginx** (porta diretta 5055, niente login unico): a differenza di Radarr/Sonarr/Prowlarr/Bazarr, Overseerr non supporta un sub-path dietro reverse proxy per via di come Next.js gestisce gli asset. Primo accesso: wizard di setup nel browser, login con l'account Plex (stesso account del server Plex), poi collega Radarr/Sonarr (Impostazioni > Servizi) usando le API key che trovi nei rispettivi `config.xml`.

## Hardlink, non copie

Radarr e Sonarr sono configurati per usare hardlink invece di copiare i file in fase di import: lo stesso file scaricato da qBittorrent e quello nella cartella organizzata della libreria sono lo stesso dato su disco (zero spazio raddoppiato), a patto che download e libreria siano sullo stesso disco. Se aggiungi un secondo disco e scarichi qualcosa destinato a finire lì, assicurati che la categoria/cartella di download usata da qBittorrent sia sullo stesso disco di destinazione, altrimenti Radarr/Sonarr copiano invece di collegare.

## Affidabilità

- **`live-restore` su Docker**: se il demone Docker si riavvia (aggiornamento, crash, comando lanciato a mano), i container restano in esecuzione invece di fermarsi e aspettare un `docker compose up -d` manuale.
- **Niente swap su disco esterno**: se un disco USB si scollega e il kernel ha pagine di memoria lì sopra, il sistema può bloccarsi. La swap resta solo sul disco di sistema.
- **Config su disco di sistema, non su disco esterno**: le config di Plex/Radarr/Sonarr/qBittorrent vivono su `/opt/mediaserver/data` (disco interno), non su un'unità removibile — se quella si scollega, perdi solo l'accesso alla libreria film (ri-scaricabile), non le config/cronologia di tutto lo stack.
