#!/usr/bin/env python3
"""Builds Resources/pokedata.json.deflate for the Pokémon tab.

Source: the PokeAPI CSV dump (https://github.com/PokeAPI/pokeapi, data/v2/csv,
BSD-3-Clause). Pass the csv folder as the first argument:

    git clone --depth 1 --filter=blob:none --sparse https://github.com/PokeAPI/pokeapi.git
    (cd pokeapi && git sparse-checkout set data/v2/csv)
    python3 scripts/gen-pokedata.py pokeapi/data/v2/csv

The optional second argument is PKHeX.Core/Resources/byte/personal; its per-game "present in
game" flags say exactly which species/forms the Switch games accept (otherwise regional dexes
are used, which miss HOME-only species).

Only game data is generated here (names, stats, learnsets, evolutions, dexes,
index maps). No artwork: icons are read from the user's own ROMs at runtime.
"""
import csv, json, os, subprocess, sys, zlib
from collections import defaultdict

CSV = sys.argv[1]
# Optional: PKHeX.Core/Resources/byte/personal (per-game "present in game" flags, GPL data tables).
PERSONAL = sys.argv[2] if len(sys.argv) > 2 else None
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "pokedata.json.deflate")
EN = "9"

def rows(name):
    with open(os.path.join(CSV, name + ".csv"), newline="", encoding="utf-8") as f:
        yield from csv.DictReader(f)

def i(v, default=0):
    return int(v) if v not in (None, "") else default

def names(table, key, col="name"):
    out = {}
    for r in rows(table):
        if r["local_language_id"] == EN:
            out[int(r[key])] = r[col]
    return out

def dense(d, fill=""):
    """dict[int -> value] to a list indexed by id (0 = unused)."""
    n = max(d) if d else 0
    return [d.get(k, fill) for k in range(n + 1)]

# --- species -----------------------------------------------------------------
species_names = names("pokemon_species_names", "pokemon_species_id")
species = {}
for r in rows("pokemon_species"):
    sid = int(r["id"])
    if sid > 10000:
        continue
    species[sid] = [
        i(r["generation_id"]), i(r["gender_rate"]), i(r["growth_rate_id"]),
        i(r["evolves_from_species_id"]), i(r["capture_rate"]), i(r["base_happiness"]),
        i(r["hatch_counter"]),
    ]

# --- pokémon (stat/learnset holders) and forms --------------------------------
mons = {}
for r in rows("pokemon"):
    mons[int(r["id"])] = {"s": int(r["species_id"]), "id": r["identifier"], "default": r["is_default"] == "1",
                          "stats": [0] * 6, "types": [0, 0], "ab": [0, 0, 0]}
for r in rows("pokemon_stats"):
    mons[int(r["pokemon_id"])]["stats"][int(r["stat_id"]) - 1] = int(r["base_stat"])
for r in rows("pokemon_types"):
    m = mons[int(r["pokemon_id"])]
    m["types"][int(r["slot"]) - 1] = int(r["type_id"])
for r in rows("pokemon_abilities"):
    m = mons[int(r["pokemon_id"])]
    slot = int(r["slot"])
    m["ab"][2 if r["is_hidden"] == "1" else slot - 1] = int(r["ability_id"])
for m in mons.values():
    if not m["types"][1]:
        m["types"][1] = m["types"][0]
    if not m["ab"][1]:
        m["ab"][1] = m["ab"][0]

form_names = {}
for r in rows("pokemon_form_names"):
    if r["local_language_id"] == EN and r["form_name"]:
        form_names[int(r["pokemon_form_id"])] = r["form_name"]

# forms[species] = [[form name, pokemon id], ...] in in-game form order
forms = defaultdict(list)
for r in sorted(rows("pokemon_forms"), key=lambda r: (int(r["pokemon_id"]), i(r["form_order"]), int(r["id"]))):
    pid = int(r["pokemon_id"])
    sid = mons[pid]["s"]
    # Gigantamax and totem looks are flags in the games, not form numbers.
    if any(t in r["form_identifier"] for t in ("gmax", "totem")):
        continue
    forms[sid].append((i(r["form_order"]), int(r["order"] or 0), form_names.get(int(r["id"]), ""), pid,
                       i(r["introduced_in_version_group_id"])))
form_table = {}
for sid, lst in forms.items():
    lst.sort(key=lambda t: (t[0], t[1]))
    form_table[sid] = [[name, pid, vg] for _, _, name, pid, vg in lst]

# --- moves, items, abilities, types, natures ---------------------------------
move_names = names("move_names", "move_id")
moves = {}
for r in rows("moves"):
    mid = int(r["id"])
    if mid > 10000:
        continue
    moves[mid] = [move_names.get(mid, r["identifier"]), i(r["type_id"]), i(r["pp"]), i(r["power"]),
                  i(r["accuracy"]), i(r["generation_id"]), i(r["damage_class_id"])]

item_names = names("item_names", "item_id")
items = {}
for r in rows("items"):
    items[int(r["id"])] = item_names.get(int(r["id"]), r["identifier"])
# itemIndex[generation] = {game index: item id}
item_index = defaultdict(dict)
for r in rows("item_game_indices"):
    item_index[int(r["generation_id"])][int(r["game_index"])] = int(r["item_id"])

ability_names = names("ability_names", "ability_id")
abilities = {k: v for k, v in ability_names.items() if k < 10000}
type_names = {k: v for k, v in names("type_names", "type_id").items() if k < 10000}
nature_names = names("nature_names", "nature_id")
natures = sorted(((int(r["game_index"]), nature_names[int(r["id"])], int(r["increased_stat_id"]), int(r["decreased_stat_id"]))
                  for r in rows("natures")))
natures = [[n, inc, dec] for _, n, inc, dec in natures]

growth = defaultdict(lambda: [0] * 101)
for r in rows("experience"):
    growth[int(r["growth_rate_id"])][int(r["level"])] = int(r["experience"])

# --- per-game species index (Gen 1–3 use their own internal numbering) --------
# gameIndex[version id] = {internal index: pokemon id}
game_index = defaultdict(dict)
for r in rows("pokemon_game_indices"):
    vid = int(r["version_id"])
    if vid in (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 19, 20):
        game_index[vid][int(r["game_index"])] = int(r["pokemon_id"])

# --- learnsets ---------------------------------------------------------------
# Version groups that share one save/game get merged (base game + DLC).
MERGE = {21: 20, 22: 20, 26: 25, 27: 25, 31: 30}
METHOD = {1: "l", 4: "m", 3: "t", 2: "e", 13: "r"}
learn = defaultdict(lambda: defaultdict(lambda: {"l": [], "m": set(), "t": set(), "e": set(), "r": set()}))
for r in rows("pokemon_moves"):
    method = METHOD.get(int(r["pokemon_move_method_id"]))
    if not method:
        continue
    vg = MERGE.get(int(r["version_group_id"]), int(r["version_group_id"]))
    entry = learn[vg][int(r["pokemon_id"])]
    mv = int(r["move_id"])
    if method == "l":
        pair = [i(r["level"]), mv]
        if pair not in entry["l"]:
            entry["l"].append(pair)
    else:
        entry[method].add(mv)
learn_out = {}
for vg, per in learn.items():
    out = {}
    for pid, e in per.items():
        d = {"l": sorted(e["l"])}
        for k in "mter":
            if e[k]:
                d[k] = sorted(e[k])
        out[pid] = d
    learn_out[vg] = out

# --- evolutions --------------------------------------------------------------
# [from species, to species, trigger, trigger item, min level, held item,
#  trade species, version group (0 = all), evolved form id, time of day]
evos = []
for r in rows("pokemon_evolution"):
    to = int(r["evolved_species_id"])
    frm = species.get(to, [0, 0, 0, 0])[3]
    if not frm:
        continue
    evos.append([frm, to, i(r["evolution_trigger_id"]), i(r["trigger_item_id"]), i(r["minimum_level"]),
                 i(r["held_item_id"]), i(r["trade_species_id"]), i(r["version_group_id"]),
                 i(r["evolved_pokemon_form_id"]), r["time_of_day"] or ""])

# --- species available per version group --------------------------------------
dex_vgs = defaultdict(set)
for r in rows("pokedex_version_groups"):
    dex_vgs[int(r["pokedex_id"])].add(MERGE.get(int(r["version_group_id"]), int(r["version_group_id"])))
regional = defaultdict(set)
for r in rows("pokemon_dex_numbers"):
    for vg in dex_vgs.get(int(r["pokedex_id"]), ()):
        regional[vg].add(int(r["species_id"]))
# Games from LGPE onward only store what their dex lists (plus overrides in Swift).
dex = {vg: sorted(regional[vg]) for vg in (19, 20, 23, 24, 25, 30) if regional.get(vg)}

# --- species/forms each Switch game can actually hold (from the games' personal tables) -----
# file, record size, flag reader, form-count offset, form-index offset, max species, version group
PERSONAL_TABLES = [
    ("personal_gg", 0x54, lambda r: True, 0x20, 0x1E, 809, 19),
    ("personal_swsh", 0xB0, lambda r: (r[0x21] >> 6) & 1 == 1, 0x20, 0x1E, 898, 20),
    ("personal_bdsp", 0x44, lambda r: (r[0x21] >> 6) & 1 == 1, 0x20, 0x1E, 493, 23),
    ("personal_la", 0xB0, lambda r: (r[0x21] >> 6) & 1 == 1, 0x20, 0x1E, 905, 24),
    ("personal_sv", 0x50, lambda r: r[0x1C] != 0, 0x1A, 0x18, 1025, 25),
    ("personal_za", 0x50, lambda r: r[0x1C] != 0, 0x1A, 0x18, 1025, 30),
]
present = {}
if PERSONAL:
    for name, size, flag, fc, fi, maxs, vg in PERSONAL_TABLES:
        path = os.path.join(PERSONAL, name)
        if not os.path.exists(path):
            continue
        raw = open(path, "rb").read()
        rec = lambda i: raw[i * size:(i + 1) * size]
        count = len(raw) // size
        table = {}
        for sp in range(1, maxs + 1):
            if sp >= count:
                break
            base = rec(sp)
            forms = []
            if name == "personal_gg":
                ok = sp <= 151 or sp in (808, 809)
                if ok:
                    table[sp] = [0]
                continue
            if flag(base):
                forms.append(0)
            nforms = base[fc]
            first = base[fi] | (base[fi + 1] << 8)
            for f in range(1, nforms):
                idx = first + f - 1 if first else 0
                if first and idx < count and flag(rec(idx)):
                    forms.append(f)
                elif not first and flag(base):
                    forms.append(f)
            if forms:
                table[sp] = forms
        present[vg] = table

commit = ""
try:
    commit = subprocess.check_output(["git", "-C", CSV, "rev-parse", "HEAD"], text=True).strip()
except Exception:
    pass

data = {
    "source": "PokeAPI " + commit,
    "species": dense(species_names),
    "speciesInfo": dense(species, []),
    "forms": {str(k): v for k, v in sorted(form_table.items())},
    "mons": {str(k): [m["s"], m["stats"], m["types"], m["ab"]] for k, m in sorted(mons.items())},
    "ids": {str(k): m["id"] for k, m in sorted(mons.items())},
    "moves": dense(moves, []),
    "items": dense(items),
    "itemIndex": {str(g): {str(k): v for k, v in sorted(m.items())} for g, m in sorted(item_index.items())},
    "abilities": dense(abilities),
    "types": dense(type_names),
    "natures": natures,
    "growth": [growth[g] for g in range(1, 7)],
    "gameIndex": {str(v): {str(k): p for k, p in sorted(m.items())} for v, m in sorted(game_index.items())},
    "learn": {str(vg): {str(p): e for p, e in sorted(per.items())} for vg, per in sorted(learn_out.items())},
    "evolutions": evos,
    "dex": {str(k): v for k, v in dex.items()},
    "present": {str(vg): {str(sp): f for sp, f in sorted(t.items())} for vg, t in present.items()},
}
raw = json.dumps(data, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
comp = zlib.compressobj(9, zlib.DEFLATED, -15)
packed = comp.compress(raw) + comp.flush()
os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "wb") as f:
    f.write(packed)
print(f"pokedata: {len(raw) / 1e6:.1f} MB json -> {len(packed) / 1e6:.2f} MB at {os.path.normpath(OUT)}")
