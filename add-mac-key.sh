#!/bin/sh
# Aggiunge una chiave pubblica SSH all'utente corrente, per accedere al server
# da un altro computer senza password.
# Uso: ./add-mac-key.sh "ssh-ed25519 AAAA... nome-chiave"
set -eu
KEY="${1:?Uso: $0 \"ssh-ed25519 AAAA... nome-chiave\" (il contenuto di id_ed25519.pub)}"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "$KEY" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo "Fatto. Chiave aggiunta per utente $(whoami)."
