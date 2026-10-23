# Media Server — contesto per agenti AI

Stack self-hosted per Plex + download automatico (Radarr/Sonarr/Prowlarr/Bazarr/Overseerr), pensato per girare su una singola macchina x86_64 (Ubuntu/Debian Server) via Docker Compose.

## Principio guida

`setup.sh` è l'**unica fonte di verità**. È idempotente (rilanciabile, salta i passi già fatti) e genera ogni credenziale (password, API key) da zero a ogni installazione — non esistono segreti hardcoded nel repo, e non devono mai essercene. Qualunque modifica alla configurazione va fatta in `setup.sh` / `docker-compose.yml` / `nginx/default.conf` / `dashboard/index.html`, mai editando a mano i file già copiati su un server in esecuzione.

## Struttura

```
setup.sh                   orchestratore: dischi, Docker, copia tutto in /opt/mediaserver, automazioni via API
docker-compose.yml         definizione servizi (dashboard, plex, qbittorrent, radarr, sonarr, prowlarr, bazarr, overseerr, flaresolverr, filebrowser)
nginx/default.conf         reverse proxy + login unico HTTP Basic (tutto tranne Plex e Overseerr)
dashboard/index.html       pagina di stato dei servizi, genera gli URL da `location.hostname`
qbittorrent/                preset iniziali (categorie, config base) — usati solo al primissimo avvio
add-mac-key.sh             aggiunge una chiave pubblica SSH all'utente corrente
```

## Non committare mai

- Qualunque file di config *live* dei servizi (contengono API key, token Plex, hash password): se mai li copi localmente per debug, vanno in una cartella ignorata da git (`backups/` è già in `.gitignore`), mai aggiunti con `git add`.
- `.env`, `.env.credentials` o qualunque file con `password`/`apikey`/`token` in chiaro.
- Prima di ogni commit su questo repo, uno scan tipo `git diff --cached | grep -niE "password|apikey|token|ApiKey>"` non è mai tempo perso.

## Gotcha noti (non ripetere il debug)

- **Deploy con sudo via SSH non interattivo**: `sudo -S cmd1 && sudo -S cmd2` in una singola chiamata SSH fallisce — solo il primo riceve la password dallo stdin piped. Un `sudo -S` per comando/chiamata SSH, oppure `sudo -S bash -c "cmd1 && cmd2"` per raggrupparli sotto un'unica autenticazione.
- **qBittorrent ignora le categorie** finché non si attivano `auto_tmm_enabled` + `use_category_paths_in_manual_mode` — altrimenti scarica tutto nel path di default, creando doppioni con l'import hardlink di Radarr/Sonarr.
- **qBittorrent chiede comunque il suo login** anche dietro al reverse proxy finché `bypass_auth_subnet_whitelist_enabled`/`bypass_auth_subnet_whitelist` non sono impostati **via API** (`/api/v2/app/setPreferences`): scriverli solo nel file ini e riavviare non basta, qBittorrent sovrascrive il file dal suo stato interno al boot. Troppi tentativi di login falliti = ban IP temporaneo (si risolve con `docker restart qbittorrent`, il ban è in memoria).
- **Radarr/Sonarr/Prowlarr rifiutano le richieste reciproche** via nome container Docker (400 "Invalid Hostname") finché non sono in `allowedHosts` l'uno dell'altro — il cambiamento richiede un riavvio del servizio per applicarsi.
- **Radarr/Sonarr/Prowlarr al primissimo avvio** nascono con `AuthenticationMethod=None` + `AuthenticationRequired=Enabled`: combinazione non valida che blocca fuori chiunque (nessun metodo di login ma login richiesto). Va tolta la riga `<AuthenticationMethod>` da `config.xml` **prima** del primo avvio del container — dopo, se il problema si ripresenta comunque, va corretto via API (`PUT /api/v3/config/host` con `authenticationRequired: disabledForLocalAddresses`), non editando di nuovo il file (l'app lo riscrive dal database a ogni boot).
- **FlareSolverr** come Indexer Proxy in Prowlarr richiede lo stesso tag (es. `flaresolverr`) sia sul proxy sia sull'indexer — senza tag condiviso non viene usato, anche se risulta configurato (bug noto di Prowlarr, non un refuso).
- **Swap mai su disco esterno/removibile**: se il disco si scollega mentre il kernel ha pagine di memoria lì sopra, il sistema può bloccarsi. La swap resta sempre sul disco di sistema.
- **Config su disco di sistema, non su disco esterno**: le config di Plex/Radarr/Sonarr/qBittorrent/Prowlarr/Bazarr/Overseerr vivono su `/opt/mediaserver/data`, sul disco interno — un'unità esterna removibile ospita solo la libreria film/serie (ri-scaricabile se persa), mai le config/cronologia dello stack.
- **`live-restore` su Docker**: se il demone si riavvia (aggiornamento, crash, comando lanciato a mano), senza questa opzione i container restano fermi finché qualcuno non rilancia `docker compose up -d` a mano — anche per ore, se nessuno se ne accorge.
- **`scp` con più file sorgente e una singola destinazione-directory appiattisce i percorsi** (perde le sottocartelle tipo `nginx/default.conf` → finisce come file singolo nella root). Copiare un file alla volta quando i percorsi contano.

## Aggiungere automazioni API (Radarr/Sonarr/Prowlarr/Bazarr/qBittorrent)

Il pattern già usato in `setup.sh` (sezione 6b) per collegare i servizi via API: leggere la API key da `config.xml`/`config.yaml` sul disco locale (mai hardcoded), chiamare l'endpoint con `curl` o un blocco Python inline (`python3 - <<'PYEOF' ... PYEOF`) per manipolazioni JSON più complesse, controllare sempre se la risorsa esiste già prima di crearla (idempotenza — lo script è pensato per essere rilanciato). Qualunque nuova automazione di questo tipo non deve mai contenere credenziali reali, solo logica che le legge a runtime da dove sono già salvate sul disco locale.
