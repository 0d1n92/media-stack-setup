#!/usr/bin/env bash
# =============================================================================
#  Media server su laptop/PC x86_64: Plex (+ Quick Sync) + qBittorrent
#  + Radarr/Sonarr/Prowlarr/FlareSolverr (opz.) + Tailscale (opz.)
#  Uso:  sudo bash setup.sh
#  Lo script e' rilanciabile: salta i passi gia' fatti.
#  I file di configurazione (docker-compose.yml, nginx/, dashboard/,
#  qbittorrent/) vivono accanto a questo script e vengono copiati in STACK_DIR.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR=/opt/mediaserver
FAST="$STACK_DIR/data"  # SSD di sistema: config, database Plex, torrent incompleti
MEDIA=/mnt/media        # disco/i esterno/i: solo libreria film/serie
TZ_NAME=Europe/Rome

c_ok()   { echo -e "\e[32m[OK]\e[0m $*"; }
c_info() { echo -e "\e[36m[..]\e[0m $*"; }
c_warn() { echo -e "\e[33m[!!]\e[0m $*"; }
die()    { echo -e "\e[31m[ERRORE]\e[0m $*"; exit 1; }
ask()    { local a; read -rp "$1 " a </dev/tty; echo "$a"; }

# --- 0. Controlli ------------------------------------------------------------
[ "$EUID" -eq 0 ] || die "Lancia con: sudo bash $0"
[ "$(uname -m)" = "x86_64" ] || die "Serve un sistema x86_64 (Debian/Ubuntu Server). Questo script non e' per ARM/Raspberry Pi."
RUN_USER=${SUDO_USER:-$(logname 2>/dev/null || echo "$USER")}
PUID=$(id -u "$RUN_USER"); PGID=$(id -g "$RUN_USER")
c_ok "Utente: $RUN_USER (UID $PUID, GID $PGID)"

c_info "Installo pacchetti base..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates parted avahi-daemon >/dev/null
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
c_ok "Pacchetti base installati"

# Hostname fisso "mediaserver": con avahi-daemon sopra, rende raggiungibile
# http://mediaserver.local/ dalla rete locale senza dover ricordare l'IP
# (richiede supporto mDNS sul dispositivo: Mac/iPhone/Android/Linux di serie,
# Windows a volte no - in quel caso usa l'IP mostrato a fine script).
if [ "$(hostname)" != "mediaserver" ]; then
  hostnamectl set-hostname mediaserver
  c_ok "Hostname impostato a 'mediaserver' (http://mediaserver.local/)"
fi

# --- 1. SSD ------------------------------------------------------------------
dev_by_label() { blkid -L "$1" 2>/dev/null || true; }

prepare_disk() {   # $1 = label, $2 = descrizione
  local label=$1 desc=$2 dev part
  if [ -n "$(dev_by_label "$label")" ]; then
    c_ok "Disco '$label' gia' pronto ($(dev_by_label "$label"))"; return
  fi
  echo; echo "Dischi USB collegati:"
  lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -i usb || die "Nessun disco USB trovato. Collega gli SSD."
  dev=$(ask "Quale dispositivo e' $desc? (es. /dev/sda)")
  [ -b "$dev" ] || die "$dev non esiste"
  lsblk -no MOUNTPOINT "$dev" | grep -q . && die "$dev ha partizioni montate: smontale prima."
  c_warn "TUTTI i dati su $dev ($(lsblk -dno SIZE,MODEL "$dev")) verranno CANCELLATI."
  [ "$(ask "Scrivi FORMATTA per confermare:")" = "FORMATTA" ] || die "Annullato."
  wipefs -a "$dev" >/dev/null
  parted -s "$dev" mklabel gpt mkpart primary ext4 0% 100%
  partprobe "$dev"; sleep 3
  part=$(lsblk -lnpo NAME "$dev" | sed -n 2p)
  mkfs.ext4 -F -q -L "$label" "$part"
  c_ok "$desc formattato ($part, etichetta '$label')"
}

add_fstab() {   # $1 label, $2 mountpoint
  local uuid; uuid=$(blkid -s UUID -o value "$(dev_by_label "$1")")
  mkdir -p "$2"
  # rimuove qualunque riga precedente per questo mountpoint (es. un vecchio bind
  # lasciato da una configurazione a disco singolo) cosi' la riga UUID aggiornata
  # viene sempre scritta, anche quando il layout dei dischi cambia tra un run e l'altro
  grep -vF " $2 " /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
  echo "UUID=$uuid $2 ext4 defaults,noatime,nofail,x-systemd.device-timeout=10 0 2" >> /etc/fstab
}

# Quanti dischi per la libreria film: possono essere di taglie/tipi diversi
# (es. un HDD esterno piu' grande in aggiunta all'SSD). I dischi gia' migrati
# da un'altra macchina con etichette ext4 "media", "media2"... vengono
# riconosciuti automaticamente.
MAX_MEDIA=6
EXISTING_MEDIA=0
for i in $(seq 1 "$MAX_MEDIA"); do
  lbl=media; [ "$i" -gt 1 ] && lbl="media$i"
  [ -n "$(dev_by_label "$lbl")" ] && EXISTING_MEDIA=$i || break
done

if [ "$EXISTING_MEDIA" -gt 0 ]; then
  N_MEDIA=$EXISTING_MEDIA
else
  N_MEDIA=$(ask "Quanti dischi usi per la libreria film (anche diversi tra loro, es. SSD + HDD esterno) [1]:")
  [[ "$N_MEDIA" =~ ^[0-9]+$ ]] && [ "$N_MEDIA" -ge 1 ] && [ "$N_MEDIA" -le "$MAX_MEDIA" ] || N_MEDIA=1
fi

MEDIA_MOUNTS=()
for i in $(seq 1 "$N_MEDIA"); do
  lbl=media; mnt="$MEDIA"; desc="l'SSD/HDD della libreria film"
  if [ "$i" -gt 1 ]; then lbl="media$i"; mnt="${MEDIA}$i"; desc="il disco aggiuntivo #$i della libreria film"; fi
  prepare_disk "$lbl" "$desc"
  add_fstab "$lbl" "$mnt"
  MEDIA_MOUNTS+=("$mnt")
done

# $FAST vive sull'SSD di sistema (dentro STACK_DIR, niente disco dedicato):
# config e download in corso non devono stare su un'unita' esterna removibile,
# altrimenti uno scollegamento si porta via Radarr/Sonarr/qBittorrent/Plex
# insieme ai film. Le unita' esterne restano solo per la libreria film/serie.
mkdir -p "$FAST"

systemctl daemon-reload
mount "$MEDIA" 2>/dev/null || true
mount -a
for m in "${MEDIA_MOUNTS[@]}"; do
  mountpoint -q "$m" || die "Montaggio di $m fallito, controlla /etc/fstab"
done
c_ok "Dischi montati: ${MEDIA_MOUNTS[*]} (rimontati in automatico al riavvio)"
# Nessuna swap su disco esterno: la swap resta su /swap.img, sull'SSD di
# sistema (gia' creata dall'installer di Ubuntu).

# --- 3. Cartelle -------------------------------------------------------------
mkdir -p "$FAST"/docker/{plex,qbittorrent/qBittorrent,radarr,prowlarr,sonarr,lidarr,bazarr,overseerr,filebrowser,gluetun} \
         "$FAST"/torrents/incomplete \
         "$STACK_DIR" "$STACK_DIR/dashboard" "$STACK_DIR/nginx"
for m in "${MEDIA_MOUNTS[@]}"; do
  mkdir -p "$m"/movies "$m"/tv "$m"/music "$m"/downloads/radarr "$m"/downloads/sonarr "$m"/downloads/lidarr "$m"/downloads/manual
  chown -R "$PUID:$PGID" "$m"
done
chown -R "$PUID:$PGID" "$FAST/docker" "$FAST/torrents"
c_ok "Cartelle create"

# --- 4. Docker ---------------------------------------------------------------
if ! command -v docker >/dev/null; then
  c_info "Installo Docker (qualche minuto)..."
  curl -fsSL https://get.docker.com | sh >/dev/null
fi
usermod -aG docker "$RUN_USER"

# live-restore: se il demone Docker si riavvia (aggiornamento, crash, comando a
# mano), i container restano su invece di fermarsi e aspettare un
# "docker compose up -d" manuale che magari non arriva per ore/giorni.
if [ ! -f /etc/docker/daemon.json ]; then
  echo '{
  "live-restore": true
}' > /etc/docker/daemon.json
fi

systemctl enable --now docker >/dev/null
systemctl restart docker
c_ok "Docker pronto (live-restore attivo)"

# --- 4b. GPU Intel (Quick Sync) -----------------------------------------------
if [ -e /dev/dri ]; then
  c_ok "GPU Intel trovata (/dev/dri) - Plex userà il transcoding hardware"
else
  c_warn "/dev/dri non trovato: Plex userà solo transcoding software (installa i driver i965/intel-media-va-driver se serve)"
fi

# --- 5. Configurazione iniziale qBittorrent ----------------------------------
QB_CONF="$FAST/docker/qbittorrent/qBittorrent/qBittorrent.conf"
if [ ! -f "$QB_CONF" ]; then
  cp "$SCRIPT_DIR/qbittorrent/qBittorrent.conf" "$QB_CONF"
  cp "$SCRIPT_DIR/qbittorrent/categories.json" "$FAST/docker/qbittorrent/qBittorrent/categories.json"
  chown -R "$PUID:$PGID" "$FAST/docker/qbittorrent"
fi
c_ok "qBittorrent preconfigurato (film finiti -> $MEDIA/movies)"

# --- 5b. Dashboard e reverse proxy -------------------------------------------
# nginx (porta 80) fa anche da reverse proxy per Radarr/Sonarr/Prowlarr/qBittorrent,
# cosi' si accede senza porte (es. http://mediaserver.local/radarr/).
cp "$SCRIPT_DIR/nginx/default.conf" "$STACK_DIR/nginx/default.conf"
cp "$SCRIPT_DIR/dashboard/index.html" "$STACK_DIR/dashboard/index.html"

# Login unico (HTTP Basic) per dashboard + tutti i servizi proxati da nginx.
HTPASSWD="$STACK_DIR/nginx/.htpasswd"
if [ ! -f "$HTPASSWD" ]; then
  DASH_USER=$(ask "Username per l'accesso al server (dashboard, Radarr, Sonarr, ecc.) [admin]:")
  DASH_USER=${DASH_USER:-admin}
  DASH_PASS=$(ask "Password per '$DASH_USER' (invio per generarne una):")
  [ -n "$DASH_PASS" ] || DASH_PASS=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c16)
  echo "$DASH_USER:$(openssl passwd -apr1 "$DASH_PASS")" > "$HTPASSWD"
  chmod 644 "$HTPASSWD"
  echo "DASHBOARD_USER=$DASH_USER" >> "$STACK_DIR/.env.credentials"
  echo "DASHBOARD_PASS=$DASH_PASS" >> "$STACK_DIR/.env.credentials"
  chmod 600 "$STACK_DIR/.env.credentials"
  c_ok "Login dashboard impostato: utente '$DASH_USER' (password salvata in $STACK_DIR/.env.credentials)"
else
  c_ok "Login dashboard gia' configurato"
fi
c_ok "Dashboard e reverse proxy copiati ($STACK_DIR)"

# --- 5c. Cosa installare ------------------------------------------------------
PROFILE_ARGS=()
if [[ "$(ask "Installare anche Radarr + Sonarr + Prowlarr + Bazarr + Overseerr + FlareSolverr? (S/n):")" =~ ^[nN] ]]; then
  ARR_YES=0
else
  ARR_YES=1
  PROFILE_ARGS+=(--profile arr)
fi

if [[ "$(ask "Installare anche Lidarr (musica)? (s/N):")" =~ ^[sSyY] ]]; then
  LIDARR_YES=1
  PROFILE_ARGS+=(--profile lidarr)
else
  LIDARR_YES=0
fi

VPN_YES=0
if [[ "$(ask "Far passare qBittorrent da una VPN (Gluetun)? (s/N):")" =~ ^[sSyY] ]]; then
  VPN_YES=1
  PROFILE_ARGS+=(--profile vpn)
  echo "Provider supportati: https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers"
  VPN_SERVICE_PROVIDER=$(ask "Nome del provider VPN (es. nordvpn, mullvad, protonvpn):")
  VPN_TYPE=$(ask "Tipo (wireguard/openvpn) [wireguard]:"); VPN_TYPE=${VPN_TYPE:-wireguard}
  VPN_SERVER_COUNTRIES=$(ask "Paese/i server (invio per il default del provider):")
  if [ "$VPN_TYPE" = "openvpn" ]; then
    OPENVPN_USER=$(ask "Username OpenVPN:")
    OPENVPN_PASSWORD=$(ask "Password OpenVPN:")
    WIREGUARD_PRIVATE_KEY=""; WIREGUARD_ADDRESSES=""
  else
    WIREGUARD_PRIVATE_KEY=$(ask "Wireguard private key:")
    WIREGUARD_ADDRESSES=$(ask "Wireguard addresses (es. 10.x.x.x/32):")
    OPENVPN_USER=""; OPENVPN_PASSWORD=""
  fi
fi

# La dashboard mostra solo i servizi che hai scelto di installare: toglie la
# card di ciascun servizio non attivo invece di lasciarla li' a mostrare
# "non raggiungibile" per sempre. Gluetun non ha una sua card (e' infrastruttura,
# non un servizio da aprire nel browser).
DASHBOARD_HTML="$STACK_DIR/dashboard/index.html"
if [ "$ARR_YES" != "1" ]; then
  for svc in Overseerr Radarr Sonarr Prowlarr Bazarr FlareSolverr; do
    sed -i "/{ name: \"$svc\",/d" "$DASHBOARD_HTML"
  done
fi
if [ "$LIDARR_YES" != "1" ]; then
  sed -i '/{ name: "Lidarr",/d' "$DASHBOARD_HTML"
fi

# --- 6. docker-compose -------------------------------------------------------
cp "$SCRIPT_DIR/docker-compose.yml" "$STACK_DIR/docker-compose.yml"

# qbittorrent dietro Gluetun condivide la rete del container gluetun: il nome
# "qbittorrent" non risolve piu' sulla rete Docker (non ha una sua interfaccia),
# quindi nginx deve puntare a "gluetun" invece che a "qbittorrent".
if [ "$VPN_YES" = "1" ]; then
  sed -i 's#http://qbittorrent:8080/#http://gluetun:8080/#' "$STACK_DIR/nginx/default.conf"
fi

# Dischi film extra (oltre al primo) e Gluetun: docker-compose.yml non li
# prevede di default, quindi vanno in un override che compose unisce da solo.
OVERRIDE="$STACK_DIR/docker-compose.override.yml"
rm -f "$OVERRIDE"
{
  OVERRIDE_HAS_CONTENT=0
  if [ "${#MEDIA_MOUNTS[@]}" -gt 1 ]; then
    OVERRIDE_HAS_CONTENT=1
    echo "services:"
    for svc in qbittorrent radarr sonarr lidarr; do
      echo "  $svc:"
      echo "    volumes:"
      for i in $(seq 2 "${#MEDIA_MOUNTS[@]}"); do
        echo "      - ${MEDIA_MOUNTS[$((i-1))]}:/data/media$i"
      done
    done
    echo "  plex:"
    echo "    volumes:"
    for i in $(seq 2 "${#MEDIA_MOUNTS[@]}"); do
      echo "      - ${MEDIA_MOUNTS[$((i-1))]}/movies:/movies$i"
    done
  fi
  if [ "$VPN_YES" = "1" ]; then
    [ "$OVERRIDE_HAS_CONTENT" = "1" ] || echo "services:"
    echo "  qbittorrent:"
    echo "    ports: !reset []"   # le porte restano solo su gluetun, non su qbittorrent
    echo "    network_mode: \"service:gluetun\""
    echo "    depends_on:"
    echo "      gluetun:"
    echo "        condition: service_started"
  fi
} > "$OVERRIDE"
[ -s "$OVERRIDE" ] && c_ok "docker-compose.override.yml generato (dischi extra e/o VPN)" || rm -f "$OVERRIDE"

echo
echo "Facoltativo: collega subito Plex al tuo account."
echo "Apri https://plex.tv/claim, copia il codice (vale 4 minuti) e incollalo qui."
PLEX_CLAIM=$(ask "Claim token (invio per saltare):")
cat > "$STACK_DIR/.env" <<EOF
PUID=$PUID
PGID=$PGID
TZ=$TZ_NAME
PLEX_CLAIM=$PLEX_CLAIM
VPN_SERVICE_PROVIDER=${VPN_SERVICE_PROVIDER:-}
VPN_TYPE=${VPN_TYPE:-}
VPN_SERVER_COUNTRIES=${VPN_SERVER_COUNTRIES:-}
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY:-}
WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES:-}
OPENVPN_USER=${OPENVPN_USER:-}
OPENVPN_PASSWORD=${OPENVPN_PASSWORD:-}
EOF
chmod 600 "$STACK_DIR/.env"

# Radarr/Sonarr/Prowlarr nascono con AuthenticationMethod=None + Required=Enabled:
# una combinazione che li blocca fuori (login impossibile, nessun account esiste).
# Rimuovendo la riga *prima del primo avvio* l'app mostra la pagina di creazione account.
# Si tocca solo se il config.xml non esiste ancora, per non resettare un login gia' fatto.
FRESH_ARR=()
if [ "$ARR_YES" = "1" ]; then
  for app in radarr sonarr prowlarr; do
    [ -f "$FAST/docker/$app/config.xml" ] || FRESH_ARR+=("$app")
  done
fi
if [ "$LIDARR_YES" = "1" ] && [ ! -f "$FAST/docker/lidarr/config.xml" ]; then
  FRESH_ARR+=("lidarr")
fi

c_info "Scarico e avvio i container (la prima volta ci vogliono qualche minuto)..."
cd "$STACK_DIR"
docker compose "${PROFILE_ARGS[@]}" pull -q
docker compose "${PROFILE_ARGS[@]}" up -d
c_ok "Container avviati"

if [ ${#FRESH_ARR[@]} -gt 0 ]; then
  c_info "Sistemo login di primo avvio e Url Base (per il reverse proxy) per: ${FRESH_ARR[*]}..."
  for app in "${FRESH_ARR[@]}"; do
    for _ in $(seq 1 30); do [ -f "$FAST/docker/$app/config.xml" ] && break; sleep 1; done
    docker stop "$app" >/dev/null 2>&1 || true
    sed -i '/<AuthenticationMethod>/d' "$FAST/docker/$app/config.xml" 2>/dev/null || true
    sed -i "s#<UrlBase></UrlBase>#<UrlBase>/$app</UrlBase>#" "$FAST/docker/$app/config.xml" 2>/dev/null || true
    docker start "$app" >/dev/null 2>&1 || true
  done
fi

# --- 6b. Collegamenti automatici: qBittorrent <-> Radarr/Sonarr/Lidarr, Prowlarr -> app --
if [ "$ARR_YES" = "1" ] || [ "$LIDARR_YES" = "1" ]; then
  c_info "Collego qBittorrent a Radarr/Sonarr/Lidarr e Prowlarr alle app (via API)..."
  for _ in $(seq 1 30); do curl -sf -o /dev/null http://localhost:8080/ && break; sleep 2; done

  # Dietro Gluetun qBittorrent non ha un suo nome risolvibile sulla rete Docker
  # (condivide quella di gluetun): le altre app vanno collegate a "gluetun".
  QB_HOST="qbittorrent"
  [ "$VPN_YES" = "1" ] && QB_HOST="gluetun"

  # Radarr/Sonarr/Lidarr/Prowlarr rifiutano (400 Invalid Hostname) le richieste
  # reciproche via nome container Docker finche' non e' in allowedHosts: senza
  # questo fix Prowlarr non riesce a sincronizzare gli indexer dentro le app.
  RESTART_NEEDED=0
  ALLOWED_APPS=()
  [ "$ARR_YES" = "1" ] && ALLOWED_APPS+=("prowlarr:9696:v1" "radarr:7878:v3" "sonarr:8989:v3")
  [ "$LIDARR_YES" = "1" ] && ALLOWED_APPS+=("lidarr:8686:v1")
  for entry in "${ALLOWED_APPS[@]}"; do
    app=${entry%%:*}; rest=${entry#*:}; port=${rest%%:*}; ver=${rest##*:}
    [ -f "$FAST/docker/$app/config.xml" ] || continue
    APP_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/$app/config.xml" 2>/dev/null || true)
    [ -n "$APP_KEY" ] || continue
    for _ in $(seq 1 30); do curl -sf -o /dev/null -H "X-Api-Key: $APP_KEY" "http://localhost:$port/$app/api/$ver/config/host" && break; sleep 2; done
    HOST_JSON=$(mktemp)
    curl -s -H "X-Api-Key: $APP_KEY" "http://localhost:$port/$app/api/$ver/config/host" \
      | python3 -c "
import json,sys
c = json.load(sys.stdin)
hosts = set(h.strip() for h in c.get('allowedHosts','').split(',') if h.strip())
hosts.update(['mediaserver.local', 'radarr', 'sonarr', 'lidarr', 'prowlarr'])
c['allowedHosts'] = ','.join(sorted(hosts))
print(json.dumps(c))
" > "$HOST_JSON" 2>/dev/null || true
    if [ -s "$HOST_JSON" ]; then
      curl -s -X PUT -H "X-Api-Key: $APP_KEY" -H "Content-Type: application/json" \
        "http://localhost:$port/$app/api/$ver/config/host" -d @"$HOST_JSON" >/dev/null
      RESTART_NEEDED=1
    fi
    rm -f "$HOST_JSON"
  done
  # allowedHosts si applica solo al riavvio del servizio.
  [ "$RESTART_NEEDED" = "1" ] && docker restart prowlarr radarr sonarr lidarr >/dev/null 2>&1 && sleep 5

  if [ ! -f "$FAST/docker/qbittorrent/qBittorrent/qBittorrent.conf" ] || ! grep -q WebUI..Password_PBKDF2 "$FAST/docker/qbittorrent/qBittorrent/qBittorrent.conf" 2>/dev/null; then
    QB_PASS_FIXED=$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c20)
    QB_TEMP_PASS=""
    for _ in $(seq 1 30); do
      QB_TEMP_PASS=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password.*: \K\S+' | tail -1 || true)
      [ -n "$QB_TEMP_PASS" ] && break; sleep 2
    done
    if [ -n "$QB_TEMP_PASS" ]; then
      JAR=$(mktemp)
      curl -s -c "$JAR" -d "username=admin&password=$QB_TEMP_PASS" http://localhost:8080/api/v2/auth/login >/dev/null
      curl -s -b "$JAR" -X POST -H "Referer: http://localhost:8080" \
        --data-urlencode "json={\"web_ui_username\":\"admin\",\"web_ui_password\":\"$QB_PASS_FIXED\"}" \
        http://localhost:8080/api/v2/app/setPreferences >/dev/null
      rm -f "$JAR"
      echo "QB_PASS_FIXED=$QB_PASS_FIXED" >> "$STACK_DIR/.env"
      chmod 600 "$STACK_DIR/.env"
    fi
  else
    QB_PASS_FIXED=$(grep -oP '(?<=^QB_PASS_FIXED=).*' "$STACK_DIR/.env" 2>/dev/null || true)
  fi

  if [ -n "${QB_PASS_FIXED:-}" ]; then
    JAR=$(mktemp)
    curl -s -c "$JAR" -d "username=admin&password=$QB_PASS_FIXED" http://localhost:8080/api/v2/auth/login >/dev/null

    # Senza questo, qBittorrent ignora il percorso delle categorie e scarica
    # tutto nel save_path di default, creando cartelle duplicate con Radarr/Sonarr.
    # bypass_auth_subnet_whitelist* va impostato via API: scriverlo solo nel file
    # ini e riavviare non basta, qBittorrent lo sovrascrive dal suo stato interno.
    # Senza, nginx passa il suo login ma qBittorrent chiede comunque il proprio
    # (e troppi tentativi falliti finiscono in un ban IP temporaneo).
    curl -s -b "$JAR" -X POST --data-urlencode "json={\"auto_tmm_enabled\":true,\"use_category_paths_in_manual_mode\":true,\"save_path\":\"/data/media/downloads/manual\",\"bypass_auth_subnet_whitelist_enabled\":true,\"bypass_auth_subnet_whitelist\":\"172.30.0.0/24\"}" \
      http://localhost:8080/api/v2/app/setPreferences >/dev/null

    curl -s -b "$JAR" -X POST --data-urlencode "category=radarr" --data-urlencode "savePath=/data/media/downloads/radarr" \
      http://localhost:8080/api/v2/torrents/createCategory >/dev/null
    curl -s -b "$JAR" -X POST --data-urlencode "category=sonarr" --data-urlencode "savePath=/data/media/downloads/sonarr" \
      http://localhost:8080/api/v2/torrents/createCategory >/dev/null
    curl -s -b "$JAR" -X POST --data-urlencode "category=lidarr" --data-urlencode "savePath=/data/media/downloads/lidarr" \
      http://localhost:8080/api/v2/torrents/createCategory >/dev/null
    rm -f "$JAR"

    DL_APPS=()
    [ "$ARR_YES" = "1" ] && DL_APPS+=(radarr sonarr)
    [ "$LIDARR_YES" = "1" ] && DL_APPS+=(lidarr)
    for app in "${DL_APPS[@]}"; do
      [ -f "$FAST/docker/$app/config.xml" ] || continue
      APP_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/$app/config.xml" 2>/dev/null || true)
      APP_PORT=7878; APP_VER="v3"; CAT_FIELD="movieCategory"; CAT_VAL="radarr"; ROOT_FOLDER="/data/media/movies"
      [ "$app" = "sonarr" ] && APP_PORT=8989 && CAT_FIELD="tvCategory" && CAT_VAL="sonarr" && ROOT_FOLDER="/data/media/tv"
      [ "$app" = "lidarr" ] && APP_PORT=8686 && APP_VER="v1" && CAT_FIELD="musicCategory" && CAT_VAL="lidarr" && ROOT_FOLDER="/data/media/music"
      [ -n "$APP_KEY" ] || continue
      APP_BASE="http://localhost:$APP_PORT/$app"

      # Root folder: senza questa, "Add Movie/Series/Artist" da' errore "Root Folder Path must not be empty".
      EXISTING_ROOT=$(curl -s -H "X-Api-Key: $APP_KEY" "$APP_BASE/api/$APP_VER/rootfolder" 2>/dev/null)
      [ "$EXISTING_ROOT" = "[]" ] && curl -s -X POST -H "X-Api-Key: $APP_KEY" -H "Content-Type: application/json" \
        "$APP_BASE/api/$APP_VER/rootfolder" -d "{\"path\":\"$ROOT_FOLDER\"}" >/dev/null

      # Hardlink invece di copia: l'import da qBittorrent non duplica i dati su disco
      # (funziona solo se download e libreria sono sullo stesso filesystem).
      for _ in $(seq 1 30); do curl -sf -o /dev/null -H "X-Api-Key: $APP_KEY" "$APP_BASE/api/$APP_VER/config/mediamanagement" && break; sleep 2; done
      MM_JSON=$(mktemp)
      curl -s -H "X-Api-Key: $APP_KEY" "$APP_BASE/api/$APP_VER/config/mediamanagement" \
        | python3 -c "import json,sys; c=json.load(sys.stdin); c['copyUsingHardlinks']=True; print(json.dumps(c))" \
        > "$MM_JSON" 2>/dev/null || true
      [ -s "$MM_JSON" ] && curl -s -X PUT -H "X-Api-Key: $APP_KEY" -H "Content-Type: application/json" \
        "$APP_BASE/api/$APP_VER/config/mediamanagement" -d @"$MM_JSON" >/dev/null
      rm -f "$MM_JSON"

      EXISTING=$(curl -s -H "X-Api-Key: $APP_KEY" "$APP_BASE/api/$APP_VER/downloadclient" 2>/dev/null)
      [ "$EXISTING" = "[]" ] || continue
      curl -s -X POST -H "X-Api-Key: $APP_KEY" -H "Content-Type: application/json" \
        "$APP_BASE/api/$APP_VER/downloadclient" -d "{
          \"enable\": true, \"protocol\": \"torrent\", \"priority\": 1,
          \"removeCompletedDownloads\": true, \"removeFailedDownloads\": true,
          \"name\": \"qBittorrent\", \"implementation\": \"QBittorrent\", \"configContract\": \"QBittorrentSettings\",
          \"fields\": [
            {\"name\":\"host\",\"value\":\"$QB_HOST\"}, {\"name\":\"port\",\"value\":8080},
            {\"name\":\"useSsl\",\"value\":false}, {\"name\":\"username\",\"value\":\"admin\"},
            {\"name\":\"password\",\"value\":\"$QB_PASS_FIXED\"}, {\"name\":\"$CAT_FIELD\",\"value\":\"$CAT_VAL\"}
          ]}" >/dev/null
    done
  fi

  if [ -f "$FAST/docker/prowlarr/config.xml" ]; then
    PROWLARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/prowlarr/config.xml" 2>/dev/null || true)
    PROWLARR_BASE="http://localhost:9696/prowlarr"
    EXISTING_APPS=$(curl -s -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_BASE/api/v1/applications" 2>/dev/null)
    if [ -n "$PROWLARR_KEY" ] && [ "$EXISTING_APPS" = "[]" ]; then
      PROWLARR_APPS=(radarr sonarr)
      [ "$LIDARR_YES" = "1" ] && PROWLARR_APPS+=(lidarr)
      for app in "${PROWLARR_APPS[@]}"; do
        [ -f "$FAST/docker/$app/config.xml" ] || continue
        APP_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/$app/config.xml" 2>/dev/null || true)
        APP_PORT=7878; APP_NAME=Radarr; APP_CONTRACT=RadarrSettings
        [ "$app" = "sonarr" ] && APP_PORT=8989 && APP_NAME=Sonarr && APP_CONTRACT=SonarrSettings
        [ "$app" = "lidarr" ] && APP_PORT=8686 && APP_NAME=Lidarr && APP_CONTRACT=LidarrSettings
        [ -n "$APP_KEY" ] || continue
        curl -s -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
          "$PROWLARR_BASE/api/v1/applications" -d "{
            \"name\": \"$APP_NAME\", \"implementation\": \"$APP_NAME\", \"configContract\": \"$APP_CONTRACT\", \"syncLevel\": \"fullSync\",
            \"fields\": [
              {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696/prowlarr\"},
              {\"name\":\"baseUrl\",\"value\":\"http://$app:$APP_PORT/$app\"},
              {\"name\":\"apiKey\",\"value\":\"$APP_KEY\"}
            ]}" >/dev/null
      done
    fi

    # FlareSolverr come Indexer Proxy, per gli indexer protetti da Cloudflare
    # (es. 1337x). Richiede il tag "flaresolverr" sia sul proxy che
    # sull'indexer: senza tag condiviso Prowlarr non lo usa (nonostante la
    # documentazione dica che tag vuoti = applica a tutti).
    if [ -n "$PROWLARR_KEY" ] && [ "$(curl -s -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_BASE/api/v1/indexerproxy")" = "[]" ]; then
      FS_TAG_ID=$(curl -s -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_BASE/api/v1/tag" | python3 -c "
import json,sys
tags = json.load(sys.stdin)
t = next((x for x in tags if x['label'] == 'flaresolverr'), None)
print(t['id'] if t else '')
" 2>/dev/null)
      if [ -z "$FS_TAG_ID" ]; then
        FS_TAG_ID=$(curl -s -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
          "$PROWLARR_BASE/api/v1/tag" -d "{\"label\":\"flaresolverr\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null)
      fi
      if [ -n "$FS_TAG_ID" ]; then
        curl -s -X POST -H "X-Api-Key: $PROWLARR_KEY" -H "Content-Type: application/json" \
          "$PROWLARR_BASE/api/v1/indexerproxy" -d "{
            \"name\": \"FlareSolverr\", \"implementation\": \"FlareSolverr\", \"configContract\": \"FlareSolverrSettings\", \"tags\": [$FS_TAG_ID],
            \"fields\": [
              {\"name\":\"host\",\"value\":\"http://flaresolverr:8191\"},
              {\"name\":\"requestTimeout\",\"value\":60}
            ]}" >/dev/null
      fi
    fi

    # Indexer pubblici di base (nessuna credenziale richiesta, niente account):
    # se Prowlarr non ne ha ancora nessuno, aggiunge un set di partenza ragionevole.
    # 1337x ed EZTV vanno dietro FlareSolverr (stesso tag "flaresolverr" di sopra).
    if [ -n "$PROWLARR_KEY" ] && [ "$(curl -s -H "X-Api-Key: $PROWLARR_KEY" "$PROWLARR_BASE/api/v1/indexer")" = "[]" ]; then
      python3 "$SCRIPT_DIR/scripts/add_public_indexers.py" "$PROWLARR_BASE" "$PROWLARR_KEY"
      c_ok "Indexer pubblici di base aggiunti a Prowlarr (1337x, The Pirate Bay, LimeTorrents, YTS, EZTV)"
    fi
  fi

  # Profili qualita' per lingua: ITA/ENG a 4K e Full HD, per Radarr e Sonarr.
  # Nessuna credenziale coinvolta: sono Custom Format basati sulla lingua
  # rilevata dal parser nativo di Sonarr/Radarr nel titolo della release, non
  # su tag testuali. Ogni profilo accetta tutte le fonti a quella risoluzione
  # (HDTV/WEB/Bluray/Remux) ma richiede che la lingua corrisponda.
  for entry in "radarr:7878" "sonarr:8989"; do
    app=${entry%%:*}; port=${entry#*:}
    [ -f "$FAST/docker/$app/config.xml" ] || continue
    APP_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/$app/config.xml" 2>/dev/null || true)
    [ -n "$APP_KEY" ] || continue
    python3 "$SCRIPT_DIR/scripts/setup_quality_profiles.py" "http://localhost:$port/$app/api/v3" "$APP_KEY"
  done
  c_ok "Profili qualita' ITA/ENG 4K + Full HD creati su Radarr e Sonarr"

  # Bazarr: sottotitoli per Radarr/Sonarr, lingua ita+eng sempre entrambe (nessun
  # cutoff: con un cutoff impostato Bazarr si ferma alla prima lingua trovata e
  # non scarica piu' l'altra).
  if [ -f "$FAST/docker/bazarr/config/config.yaml" ]; then
    BAZARR_KEY=$(awk '/^auth:/{f=1;next} /^[a-zA-Z]/{f=0} f' "$FAST/docker/bazarr/config/config.yaml" | grep -oP '(?<=apikey: ).+' || true)
    BAZARR_BASE="http://localhost:6767"
    for _ in $(seq 1 30); do curl -sf -o /dev/null -H "X-API-KEY: $BAZARR_KEY" "$BAZARR_BASE/api/system/status" && break; sleep 2; done
    RADARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/radarr/config.xml" 2>/dev/null || true)
    SONARR_KEY=$(grep -oP '(?<=<ApiKey>)[^<]+' "$FAST/docker/sonarr/config.xml" 2>/dev/null || true)
    if [ -n "$BAZARR_KEY" ] && [ -n "$RADARR_KEY" ] && [ -n "$SONARR_KEY" ]; then
      # L'API di Bazarr vuole i booleani in minuscolo ("true"/"false"): "True"/"False"
      # passano la validazione del form ma vengono salvati come stringa e rifiutati (406).
      curl -s -H "X-API-KEY: $BAZARR_KEY" -X POST \
        --data-urlencode "settings-general-use_radarr=true" \
        --data-urlencode "settings-general-use_sonarr=true" \
        --data-urlencode "settings-general-base_url=/bazarr" \
        --data-urlencode "settings-general-serie_default_enabled=true" \
        --data-urlencode "settings-general-movie_default_enabled=true" \
        --data-urlencode "settings-radarr-ip=radarr" --data-urlencode "settings-radarr-port=7878" \
        --data-urlencode "settings-radarr-base_url=/radarr" --data-urlencode "settings-radarr-apikey=$RADARR_KEY" \
        --data-urlencode "settings-radarr-ssl=false" \
        --data-urlencode "settings-sonarr-ip=sonarr" --data-urlencode "settings-sonarr-port=8989" \
        --data-urlencode "settings-sonarr-base_url=/sonarr" --data-urlencode "settings-sonarr-apikey=$SONARR_KEY" \
        --data-urlencode "settings-sonarr-ssl=false" \
        "$BAZARR_BASE/api/system/settings" >/dev/null

      # Profilo lingua "ita": italiano + inglese, senza cutoff cosi' li scarica
      # sempre entrambi invece di fermarsi al primo trovato.
      curl -s -H "X-API-KEY: $BAZARR_KEY" -X POST \
        --data-urlencode "languages-enabled=it" --data-urlencode "languages-enabled=en" \
        --data-urlencode 'languages-profiles=[{"profileId":1,"name":"ita","cutoff":null,"items":[{"id":1,"language":"it","forced":"False","hi":"False","audio_exclude":"False","audio_only_include":"False"},{"id":2,"language":"en","forced":"False","hi":"False","audio_exclude":"False","audio_only_include":"False"}],"mustContain":[],"mustNotContain":[],"originalFormat":null}]' \
        --data-urlencode "settings-general-serie_default_profile=1" \
        --data-urlencode "settings-general-movie_default_profile=1" \
        "$BAZARR_BASE/api/system/settings" >/dev/null
      c_ok "Bazarr collegato a Radarr/Sonarr (sottotitoli ita+eng, senza cutoff)"
      c_warn "Bazarr non ha ancora un provider di sottotitoli: aggiungilo in Impostazioni > Provider (es. OpenSubtitles.com, serve un account gratuito)"
    fi
  fi
  c_ok "qBittorrent e Prowlarr collegati a Radarr/Sonarr"
fi

# --- 7. Tailscale (accesso da fuori casa) ------------------------------------
if [[ "$(ask "Installare Tailscale per accedere da fuori casa? (S/n):")" =~ ^[nN] ]]; then
  :
else
  command -v tailscale >/dev/null || curl -fsSL https://tailscale.com/install.sh | sh >/dev/null
  echo "Apri il link che compare qui sotto e accedi col tuo account (anche Google):"
  tailscale up || c_warn "Tailscale non configurato, riprova dopo con: sudo tailscale up"
fi

# --- 8. Riepilogo ------------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')
QB_PASS="${QB_PASS_FIXED:-}"
if [ -z "$QB_PASS" ]; then
  for _ in $(seq 1 30); do
    QB_PASS=$(docker logs qbittorrent 2>&1 | grep -oP 'temporary password.*: \K\S+' | tail -1 || true)
    [ -n "$QB_PASS" ] && break; sleep 2
  done
fi

if [ -z "${DASH_USER:-}" ] && [ -f "$STACK_DIR/.env.credentials" ]; then
  DASH_USER=$(grep -oP '(?<=^DASHBOARD_USER=).*' "$STACK_DIR/.env.credentials" 2>/dev/null || true)
  DASH_PASS=$(grep -oP '(?<=^DASHBOARD_PASS=).*' "$STACK_DIR/.env.credentials" 2>/dev/null || true)
fi

echo
echo "=================================================================="
echo " FATTO! Il media server e' attivo."
echo "=================================================================="
echo " Dashboard:     http://$IP/  (o http://mediaserver.local/)   utente: ${DASH_USER:-?}   password: ${DASH_PASS:-vedi $STACK_DIR/.env.credentials}"
echo "                Stesso login per tutto quello che passa dal reverse proxy (sotto)."
echo " Plex:          http://$IP:32400/web   (account plex.tv separato, non c'entra col login sopra)"
if [ "$VPN_YES" = "1" ]; then
echo " qBittorrent:   http://$IP/qbittorrent/   (traffico instradato dalla VPN via Gluetun)"
else
echo " qBittorrent:   http://$IP/qbittorrent/   (nessun login extra se apri da qui; su :8080 diretto serve ancora quello suo)"
fi
if [ "$ARR_YES" = "1" ]; then
echo " Radarr:        http://$IP/radarr/     (nessun login extra)"
echo " Sonarr:        http://$IP/sonarr/     (nessun login extra)"
echo " Prowlarr:      http://$IP/prowlarr/   (nessun login extra; poi Indexers > Add Indexer)"
echo " Bazarr:        http://$IP/bazarr/     (nessun login extra; aggiungi un provider sottotitoli in Impostazioni > Provider)"
echo " Overseerr:     http://$IP:5055/       (primo accesso: wizard di setup nel browser, login con l'account Plex)"
echo " FlareSolverr:  http://$IP:8191/       (per gli indexer protetti da Cloudflare come 1337x,"
echo "                aggiungi il tag 'flaresolverr' all'indexer in Prowlarr, altrimenti non viene usato)"
fi
if [ "$LIDARR_YES" = "1" ]; then
echo " Lidarr:        http://$IP/lidarr/     (nessun login extra)"
fi
if [ "$ARR_YES" = "1" ] || [ "$LIDARR_YES" = "1" ]; then
echo "                In ciascuno, in Allowed Hosts metti: mediaserver.local,$IP,radarr,sonarr,lidarr,prowlarr"
echo "                qBittorrent e' gia' collegato alle app installate, e Prowlarr e' gia' collegato a tutte."
echo "                Niente porte da ricordare: tutto passa dal reverse proxy nginx sulla porta 80."
fi
echo " File:          http://$IP/files/      (sfoglia/carica file nei dischi media)"
command -v tailscale >/dev/null && echo " IP Tailscale:  $(tailscale ip -4 2>/dev/null || echo 'non ancora collegato')"
echo
echo " In Plex: aggiungi una libreria 'Film' con cartella /movies"
if [ "${#MEDIA_MOUNTS[@]}" -gt 1 ]; then
  for i in $(seq 2 "${#MEDIA_MOUNTS[@]}"); do
    echo "          e aggiungi anche /movies$i come seconda cartella della stessa libreria (disco extra)"
  done
fi
echo " Riavvia la macchina una volta (sudo reboot) per applicare tutto."
echo "=================================================================="
