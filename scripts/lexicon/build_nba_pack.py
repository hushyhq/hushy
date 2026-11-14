#!/usr/bin/env python3
"""Build the NBA domain pack (Sources/MurmurCore/Lexicon/Packs/sports.nba.json) from Wikidata (CC0 1.0).

Players: every human with an NBA.com player ID (P3647) of 201000 or more (debut about 2008 on), or an earlier one
with 30 or more sitelinks, and a birth date from 1978 on. Teams: the 30 current NBA franchises (P118 = NBA, instance of basketball team, not dissolved).
Ranked by Wikidata sitelink count (a proxy for how often a name is written about), most first.

Developer-time only: the app never fetches anything; the JSON is bundled into the binary (DomainPackData.swift).

    python3 -I scripts/lexicon/build_nba_pack.py --cache <empty scratch dir>
    python3 -I scripts/lexicon/embed_packs.py
"""
import argparse, json, os, sys, time, unicodedata, urllib.error, urllib.parse, urllib.request

UA = {"User-Agent": "HushyLexiconBuilder/0.1 (dev-time pack build)"}
SPARQL = "https://query.wikidata.org/sparql"
API = "https://www.wikidata.org/w/api.php"
TEAMS_QUERY = """SELECT ?team ?teamLabel ?links WHERE {
  ?team wdt:P118 wd:Q155223 ; wdt:P31 wd:Q13393265 ; wikibase:sitelinks ?links .
  FILTER NOT EXISTS { ?team wdt:P576 ?d }
  SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
} ORDER BY DESC(?links)"""
PLAYERS_QUERY = """SELECT ?player ?nbaid ?born WHERE {
  ?player wdt:P3647 ?nbaid ; wdt:P569 ?born .
  FILTER (?born >= "1978-01-01T00:00:00Z"^^xsd:dateTime)
}"""
MIN_NBA_ID = 201000
VETERAN_SITELINKS = 30


def get(url, params):
    request = urllib.request.Request(url + "?" + urllib.parse.urlencode(params), headers={**UA, "Accept": "application/sparql-results+json"})
    for _ in range(10):
        try:
            return json.load(urllib.request.urlopen(request, timeout=120))
        except urllib.error.HTTPError as error:
            if error.code != 429:
                raise
            time.sleep(int(error.headers.get("Retry-After") or 10) + 1)
    raise RuntimeError("rate limited")


def cached(cache, name, fetch):
    path = os.path.join(cache, name)
    if os.path.exists(path):
        return json.load(open(path))
    value = fetch()
    json.dump(value, open(path, "w"))
    return value


def entities(ids):
    out = {}
    for start in range(0, len(ids), 50):
        data = get(API, {"action": "wbgetentities", "ids": "|".join(ids[start:start + 50]),
                         "props": "labels|aliases|sitelinks", "languages": "en|mul", "format": "json"})
        for qid, entity in data["entities"].items():
            labels = entity.get("labels", {})
            # Wikidata moved many names to the language-neutral "mul" label (Kevin Durant has no "en" one).
            out[qid] = {"label": (labels.get("en") or labels.get("mul") or {}).get("value"),
                        "aliases": [a["value"] for a in entity.get("aliases", {}).get("en", [])],
                        "sitelinks": len(entity.get("sitelinks", {}))}
        time.sleep(2)
    return out


def fold(text):
    return "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c)).lower()


def spelling_aliases(label, aliases):
    """Only spelling variants of the label (an unaccented "Luka Doncic"), never nicknames ("Uncle Drew")."""
    keep = []
    for alias in aliases + [unicodedata.normalize("NFKD", label).encode("ascii", "ignore").decode()]:
        if alias != label and fold(alias) == fold(label) and alias not in keep:
            keep.append(alias)
    return keep


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", required=True, help="scratch folder for the raw Wikidata answers")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "../../Sources/MurmurCore/Lexicon/Packs/sports.nba.json"))
    parser.add_argument("--version", default=time.strftime("%Y-%m-%d"))
    args = parser.parse_args()
    os.makedirs(args.cache, exist_ok=True)
    teams = cached(args.cache, "teams.json", lambda: get(SPARQL, {"query": TEAMS_QUERY}))["results"]["bindings"]
    players = cached(args.cache, "players.json", lambda: get(SPARQL, {"query": PLAYERS_QUERY}))["results"]["bindings"]
    nba_id = {p["player"]["value"].rsplit("/", 1)[1]: int(p["nbaid"]["value"]) for p in players if p["nbaid"]["value"].isdigit()}
    people = cached(args.cache, "entities.json", lambda: entities(sorted(nba_id)))
    missing = sorted((set(nba_id) - set(people)) | {q for q, e in people.items() if not e["label"]})
    if missing:
        people.update(entities(missing))
        json.dump(people, open(os.path.join(args.cache, "entities.json"), "w"))
    # Recent players (an NBA.com ID from about 2008 on), and earlier ones still written about a lot (LeBron James).
    people = {q: e for q, e in people.items() if nba_id.get(q, 0) >= MIN_NBA_ID or e["sitelinks"] >= VETERAN_SITELINKS}
    terms = []
    ranked = sorted(((e["sitelinks"], e["label"], e["aliases"]) for e in people.values()
                     if e["label"] and len(e["label"].split()) >= 2), key=lambda r: (-r[0], r[1]))
    seen = set()
    for _, label, aliases in ranked:
        if label.lower() in seen:
            continue
        seen.add(label.lower())
        terms.append({"surface": label, "aliases": spelling_aliases(label, aliases), "kind": "person"})
    for team in teams:
        terms.append({"surface": team["teamLabel"]["value"], "aliases": [], "kind": "org"})
    pack = {
        "id": "sports.nba", "version": args.version, "title": "NBA players and teams",
        "licence": "CC0-1.0", "sourceURL": "https://www.wikidata.org/",
        "sourceNote": "Wikidata: humans with an NBA.com player ID (P3647) >= %d born 1978 or later, ranked by sitelinks; the 30 current NBA franchises." % MIN_NBA_ID,
        "terms": terms,
    }
    with open(args.out, "w", encoding="utf-8") as handle:
        json.dump(pack, handle, ensure_ascii=False, indent=0, sort_keys=False)
        handle.write("\n")
    print(f"{len(terms)} terms -> {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
