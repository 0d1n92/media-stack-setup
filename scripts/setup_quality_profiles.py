"""Crea su Radarr/Sonarr 4 profili qualita' per lingua: ITA/ENG a 4K e Full HD.
Ogni profilo e' un Custom Format basato sulla lingua rilevata dal parser
nativo dell'app nel titolo della release (non su tag testuali), con score
minimo 100: solo la lingua scelta vale 100 punti, l'altra 0, quindi l'app
scarta le release senza quella lingua.

Uso: python3 setup_quality_profiles.py <app_base_url> <api_key>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _servarr_api import ServarrClient

PRIORITY = ["remux", "bluray", "web", "hdtv", "raw-hd"]


def item_resolution(item):
    if "quality" in item:
        return item["quality"]["resolution"]
    return item["items"][0]["quality"]["resolution"]


def item_priority(item):
    name = (item.get("name") or item["quality"]["name"]).lower()
    for idx, key in enumerate(PRIORITY):
        if key in name:
            return idx
    return len(PRIORITY)


def ensure_format(client, name, lang_id):
    for cf in client.call("GET", "/customformat"):
        if cf["name"] == name:
            return cf["id"]
    cf = client.call("POST", "/customformat", {
        "name": name,
        "includeCustomFormatWhenRenaming": False,
        "specifications": [{
            "name": name,
            "implementation": "LanguageSpecification",
            "negate": False,
            "required": True,
            "fields": [{"name": "value", "value": lang_id}, {"name": "exceptLanguage", "value": False}],
        }],
    })
    return cf["id"]


def ensure_profile(client, name, resolution, format_id):
    if any(p["name"] == name for p in client.call("GET", "/qualityprofile")):
        return
    schema = client.call("GET", "/qualityprofile/schema")
    matching = [it for it in schema["items"] if item_resolution(it) == resolution]
    if not matching:
        return
    for it in schema["items"]:
        it["allowed"] = it in matching
    cutoff_item = sorted(matching, key=item_priority)[0]
    all_formats = client.call("GET", "/customformat")

    schema["name"] = name
    schema["upgradeAllowed"] = True
    schema["cutoff"] = cutoff_item.get("id") or cutoff_item["quality"]["id"]
    schema["formatItems"] = [
        {"format": cf["id"], "name": cf["name"], "score": 100 if cf["id"] == format_id else 0}
        for cf in all_formats
    ]
    schema["minFormatScore"] = 100
    schema["cutoffFormatScore"] = 100
    schema["minUpgradeFormatScore"] = 1
    client.call("POST", "/qualityprofile", schema)


def main(base_url, api_key):
    client = ServarrClient(base_url, api_key)
    it_id = ensure_format(client, "Italian", 5)
    en_id = ensure_format(client, "English", 1)
    ensure_profile(client, "ITA 4K", 2160, it_id)
    ensure_profile(client, "ITA Full HD", 1080, it_id)
    ensure_profile(client, "ENG 4K", 2160, en_id)
    ensure_profile(client, "ENG Full HD", 1080, en_id)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
