#!/usr/bin/env python3
"""Generate Tests/typo_gate_fixture.json for the phrases-branch CI test
(Tests/TypoCorrectionTests.swift) from the calibration artifacts:
- gate_rows.jsonl  (per-item winners from gate_calibrate.py)
- typo_dump.json   (typo_kana per item)
- typo_fixture.json (clean romaji + typo kind per item)

true_kana_in_variants is recomputed with the same budgeted selection the
production Swift port uses, so the Swift test can assert port parity.
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTO = HERE.parent
sys.path.insert(0, str(HERE))

from gen_typo_fixture import kana_to_romaji, to_hira  # noqa: E402
from gate_calibrate import kind_kana_sets, budgeted_selection  # noqa: E402

OUT = Path.home() / "workspace/numberkey-phrases/Tests/typo_gate_fixture.json"


def main():
    dump = {it["kana"]: it for it in json.loads((PROTO / "typo_dump.json").read_text(encoding="utf-8"))}
    fixture = {it["kana"]: it for it in json.loads((PROTO / "typo_fixture.json").read_text(encoding="utf-8"))}
    clean_raw = json.loads((PROTO / "candidates.json").read_text(encoding="utf-8"))
    clean_keys = {to_hira(it["kana"]) for it in clean_raw}
    rows = {}
    for line in (HERE / "gate_rows.jsonl").read_text(encoding="utf-8").splitlines():
        if line.strip():
            r = json.loads(line)
            rows[r["kana"]] = r

    items = []
    for kana in sorted(rows):
        if kana not in clean_keys or kana not in dump or kana not in fixture:
            continue
        r, d, fx = rows[kana], dump[kana], fixture[kana]
        typo_roma = kana_to_romaji(d["typo_kana"])
        sel = budgeted_selection(kind_kana_sets(typo_roma)) if typo_roma else []
        items.append({
            "kana": kana,
            "romaji": fx["romaji"],
            "typo_kana": d["typo_kana"],
            "expected": d["expected"],
            "typo_kind": fx.get("typo_kind", "?"),
            "clean_lm_winner": (r["clean_win"] or {}).get("s"),
            "true_kana_in_variants": kana in sel,
        })
    OUT.write_text(json.dumps({"items": items}, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"wrote {len(items)} items to {OUT}")
    print("true_kana_in_variants:", sum(1 for it in items if it["true_kana_in_variants"]), "/", len(items))


if __name__ == "__main__":
    main()
