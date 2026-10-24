"""Client minimale per le API di Radarr/Sonarr/Lidarr/Prowlarr (stdlib, nessuna dipendenza)."""
import json
import urllib.request


class ServarrClient:
    def __init__(self, base_url, api_key):
        self.base_url = base_url
        self.api_key = api_key

    def call(self, method, path, data=None):
        body = json.dumps(data).encode() if data is not None else None
        req = urllib.request.Request(f"{self.base_url}{path}", data=body, method=method)
        req.add_header("X-Api-Key", self.api_key)
        if body:
            req.add_header("Content-Type", "application/json")
        with urllib.request.urlopen(req) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
