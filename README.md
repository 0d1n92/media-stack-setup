# Media Server

Il tuo "Netflix privato": un server a casa che scarica film e serie TV e te li fa guardare da Plex, con una pagina per cercare e richiedere titoli senza dover capire nulla di informatica.

## Come si usa (nessuna competenza tecnica richiesta)

Chi ha installato il server (vedi sezione "Installazione" più sotto) ti darà due indirizzi da salvare nei preferiti del browser. Puoi usare `mediaserver.local` al posto dell'IP (più facile da ricordare, e non cambia mai) — su Mac/iPhone/Android/Linux funziona di serie; su alcuni PC Windows potrebbe non funzionare, in quel caso usa l'IP mostrato dall'installazione:

- **La pagina principale** (es. `http://mediaserver.local/` o `http://192.168.1.50/`): da lì apri la dashboard con lo stato di tutti i servizi. Ti chiederà un utente e una password — quelli impostati durante l'installazione.
- **La pagina per richiedere film/serie** (Overseerr, es. `http://mediaserver.local:5055/` o `http://192.168.1.50:5055/`): cerchi un titolo, clicchi "richiedi", e il server inizia a scaricarlo da solo. Login con l'account Plex.

Per **guardare** quello che hai richiesto, apri l'app Plex (su TV, telefono, computer) e fai login con il tuo account plex.tv — appena il download e l'organizzazione del file sono finiti, il titolo compare nella libreria.

I sottotitoli (italiano e inglese) vengono scaricati e sincronizzati in automatico, non serve cercarli a mano.

Se non sei sulla stessa rete Wi-Fi di casa (sei fuori), serve l'app **Tailscale** installata e collegata con lo stesso account usato sul server: senza, gli indirizzi sopra non si raprono da fuori casa.

Se un indirizzo smette di funzionare, chiedi a chi ha installato il server: probabilmente il router ha cambiato l'indirizzo della macchina.

---

## Installazione (per chi gestisce il server)

Le sezioni seguenti sono per chi configura e mantiene il server (richiede accesso SSH/terminale alla macchina).

### Requisiti

- Un computer dedicato (non il tuo PC di tutti i giorni) con Debian/Ubuntu Server, anche senza interfaccia grafica
- GPU Intel con Quick Sync (consigliata ma non obbligatoria: velocizza la conversione video, "transcoding", di Plex — senza, Plex usa la CPU)
- Uno o più dischi USB (anche di marche/dimensioni diverse) per conservare film e serie
- Accesso SSH e `sudo` sulla macchina (l'utenza amministratore)

### Lanciare l'installazione

```bash
git clone <url-di-questo-repo>
cd media-stack-setup
sudo bash setup.sh
```

Lo script (`setup.sh`) fa tutto da solo: prepara i dischi, installa Docker (il programma che fa girare ciascun servizio in un suo "contenitore" isolato) e collega i vari servizi tra loro. Si può rilanciare quante volte vuoi — salta i passi già fatti, utile se si interrompe o se in futuro aggiungi un disco.

Durante l'esecuzione chiede:
- quanti dischi usare per la libreria film
- se usare un disco separato per configurazioni/download o una cartella del primo disco
- username/password per l'accesso al server (vale per dashboard, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent)
- se installare anche Radarr/Sonarr/Prowlarr/Bazarr/FlareSolverr (i programmi che cercano e organizzano i download — vedi sotto cosa fa ciascuno)
- claim token Plex (opzionale, per collegare subito l'account Plex)
- se installare Tailscale (per l'accesso da fuori casa)

Alla fine stampa un riepilogo con tutti gli indirizzi e le password da consegnare a chi userà il server.

### Indirizzo del server

Lo script imposta l'hostname della macchina a `mediaserver` e installa `avahi-daemon` (mDNS), così il server è raggiungibile come `http://mediaserver.local/` da qualunque dispositivo sulla stessa rete che supporti mDNS (Mac, iPhone, Android, Linux di serie; su Windows a volte serve installare Bonjour o non funziona). Funziona sempre, anche se il router cambia l'IP della macchina.

Il riepilogo finale di `setup.sh` mostra anche l'IP diretto (es. `http://192.168.1.50/`) come alternativa/fallback. Se preferisci usare solo quello, può cambiare in futuro: in quel caso rilancia `sudo bash setup.sh` per leggere il nuovo IP, oppure riserva un IP fisso al server dal pannello del router ("DHCP reservation"/"IP statico").

Per l'accesso da fuori casa, Tailscale (se installato) crea un secondo IP valido ovunque, mostrato nello stesso riepilogo.

### A cosa serve ciascun servizio

- **Plex**: dove si guardano film e serie.
- **Overseerr**: dove si cercano e richiedono nuovi titoli (pensata per chi guarda, non per chi amministra).
- **Radarr / Sonarr**: ricevono le richieste e cercano il file da scaricare, uno per i film e uno per le serie.
- **Prowlarr**: il motore di ricerca condiviso da Radarr e Sonarr (gli "indexer", cioè le fonti dove cercare, si configurano qui una volta).
- **Bazarr**: cerca e sincronizza i sottotitoli per quello che Radarr/Sonarr hanno scaricato.
- **qBittorrent**: scarica materialmente i file.
- **FlareSolverr**: serve solo per gli indexer protetti da Cloudflare (es. 1337x) — aiuta Prowlarr a superare quella protezione.
- **Dashboard**: la pagina di partenza con lo stato di tutti questi servizi.

### Struttura del progetto

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

### Login

C'è **un solo login** per tutto quello che passa dal reverse proxy nginx (dashboard, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent via `/qbittorrent/`): le credenziali si impostano al primo avvio e vengono salvate in `/opt/mediaserver/.env.credentials` sulla macchina.

**Plex resta separato**: usa il tuo account plex.tv, non il login del reverse proxy — per scelta, dato che è legato alla tua identità Plex vera.

qBittorrent accetta connessioni senza password solo se arrivano dal reverse proxy (stessa rete Docker); se apri la sua porta diretta (`:8080`) ti chiede comunque le sue credenziali.

### Più dischi per la libreria film

Se in futuro aggiungi un disco (es. un HDD più grande), rilancia `sudo bash setup.sh`: lo script riconosce i dischi già montati e ti chiede solo di formattare quello nuovo. I dischi aggiuntivi vengono montati su `/mnt/media2`, `/mnt/media3`, ecc., e collegati automaticamente ai container tramite `docker-compose.override.yml` (generato in automatico, non va editato a mano).

In Plex, dopo, aggiungi `/movies2`, `/movies3`... come cartelle aggiuntive della stessa libreria "Film" — i file sui dischi extra funzionano allo stesso modo, basta aggiungere la cartella.

### Transcoding

Lo script passa `/dev/dri` al container Plex per il Quick Sync Intel, se presente sull'hardware. Il transcoding hardware è però una funzione **Plex Pass**: senza un abbonamento attivo sull'account plex.tv collegato, l'opzione "Use hardware acceleration when available" non compare nemmeno nelle impostazioni. Senza Plex Pass, Plex fa transcoding software sulla CPU — se il tuo hardware è modesto, vale la pena impostare in Plex:
- **Transcoder quality = Automatic** (non "Make my CPU hurt", che forza la massima qualità anche quando la CPU non riesce a starci dietro in tempo reale)
- **Max transcode simultanei** = un numero basso (2 su una CPU a 8 thread è un buon punto di partenza)
- **Transcoder temp directory** su un tmpfs (RAM) se hai margine di memoria, per non consumare scritture sull'SSD

### Indexer pubblici e profili qualità, già pronti

Se Prowlarr non ha ancora nessun indexer configurato, lo script ne aggiunge un set di partenza (1337x, The Pirate Bay, LimeTorrents, YTS, EZTV) — tutti pubblici, nessun account/credenziale richiesta. Puoi aggiungerne altri (anche privati, con le tue credenziali) in qualunque momento da Prowlarr, questo è solo un punto di partenza.

Crea anche 4 profili qualità su Radarr e Sonarr — **ITA 4K**, **ITA Full HD**, **ENG 4K**, **ENG Full HD** — basati sulla lingua rilevata nel titolo della release (non su tag testuali: usa il parser nativo di Sonarr/Radarr), così puoi assegnare a ogni film/serie la combinazione risoluzione+lingua che vuoi.

### Indexer protetti da Cloudflare (es. 1337x)

FlareSolverr è già configurato come Indexer Proxy in Prowlarr con il tag `flaresolverr`. Quando aggiungi un indexer che richiede FlareSolverr (Prowlarr lo segnala nella pagina dell'indexer), devi assegnargli lo stesso tag `flaresolverr` in "Add Indexer" — senza quel tag condiviso, Prowlarr non instrada le richieste tramite il proxy nonostante sia configurato.

### Sottotitoli (Bazarr)

Bazarr è collegato a Radarr e Sonarr e cerca sottotitoli in **italiano e inglese per ogni film/episodio** (profilo lingua `ita`, senza "cutoff": a differenza del comportamento di default, non si ferma alla prima lingua trovata, li scarica sempre entrambi). Serve un provider di sottotitoli configurato in Impostazioni > Provider (es. OpenSubtitles.com, account gratuito).

**Sync automatico**: ogni sottotitolo scaricato viene risincronizzato in automatico sull'audio del video (`ffsubsync`, Impostazioni > Sottotitoli > "Use Subsync") — utile quando il provider trova solo un match testuale e non un hash esatto sul file. Per un sottotitolo già scaricato prima di questa opzione, va risincronizzato a mano una volta (pagina del film/episodio in Bazarr > icona di sync sul sottotitolo).

### Richiesta film/serie (Overseerr)

Overseerr (`http://<IP>:5055/`) è un'interfaccia di ricerca/richiesta: chi guarda cerca un titolo nel catalogo TMDB (con filtri per genere, studio, anno, voto, oltre a caroselli "di tendenza"/"in arrivo"), lo richiede con un click, e Overseerr lo manda in automatico a Radarr/Sonarr — senza dare accesso diretto a Radarr/Sonarr a chi non deve gestirne la configurazione.

**Non passa dal reverse proxy nginx** (porta diretta 5055, niente login unico): a differenza di Radarr/Sonarr/Prowlarr/Bazarr, Overseerr non supporta un sub-path dietro reverse proxy per via di come Next.js gestisce gli asset. Primo accesso: wizard di setup nel browser, login con l'account Plex (stesso account del server Plex), poi collega Radarr/Sonarr (Impostazioni > Servizi) usando le API key che trovi nei rispettivi `config.xml`.

### Hardlink, non copie

Radarr e Sonarr sono configurati per usare hardlink invece di copiare i file in fase di import: lo stesso file scaricato da qBittorrent e quello nella cartella organizzata della libreria sono lo stesso dato su disco (zero spazio raddoppiato), a patto che download e libreria siano sullo stesso disco. Se aggiungi un secondo disco e scarichi qualcosa destinato a finire lì, assicurati che la categoria/cartella di download usata da qBittorrent sia sullo stesso disco di destinazione, altrimenti Radarr/Sonarr copiano invece di collegare.

### Affidabilità

- **`live-restore` su Docker**: se il demone Docker si riavvia (aggiornamento, crash, comando lanciato a mano), i container restano in esecuzione invece di fermarsi e aspettare un `docker compose up -d` manuale.
- **Niente swap su disco esterno**: se un disco USB si scollega e il kernel ha pagine di memoria lì sopra, il sistema può bloccarsi. La swap resta solo sul disco di sistema.
- **Config su disco di sistema, non su disco esterno**: le config di Plex/Radarr/Sonarr/qBittorrent vivono su `/opt/mediaserver/data` (disco interno), non su un'unità removibile — se quella si scollega, perdi solo l'accesso alla libreria film (ri-scaricabile), non le config/cronologia di tutto lo stack.
