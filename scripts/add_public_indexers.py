"""Aggiunge a Prowlarr un set di indexer pubblici di partenza (nessuna
credenziale richiesta). Chiamato da setup.sh solo se Prowlarr non ha ancora
nessun indexer configurato.

Uso: python3 add_public_indexers.py <prowlarr_base_url> <api_key>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _servarr_api import ServarrClient

NEEDS_FLARESOLVERR = {"1337x", "eztv"}
STARTER_INDEXERS = ["1337x", "thepiratebay", "limetorrents", "yts", "eztv"]


def main(base_url, api_key):
    client = ServarrClient(base_url, api_key)

    tags = client.call("GET", "/tag")
    fs_tag = next((t["id"] for t in tags if t["label"] == "flaresolverr"), None)

    schema = client.call("GET", "/indexer/schema")
    by_def = {i["definitionName"]: i for i in schema}

    for defname in STARTER_INDEXERS:
        indexer = by_def.get(defname)
        if not indexer:
            continue
        indexer["appProfileId"] = 1
        indexer["enable"] = True
        for field in indexer["fields"]:
            if field["name"] == "baseUrl" and indexer.get("indexerUrls"):
                field["value"] = indexer["indexerUrls"][0]
        if defname in NEEDS_FLARESOLVERR and fs_tag is not None:
            indexer["tags"] = [fs_tag]
        try:
            client.call("POST", "/indexer", indexer)
        except Exception as e:
            print(f"  indexer {defname}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
