#!/usr/bin/env python3
"""Build the typo-correction eval fixture.

Model: the user types romaji on QWERTY. A typo is ONE physical edit at the
romaji level (adjacent-key substitution, deletion, transposition, adjacent
insertion). The correction feature would generate all 1-edit romaji variants
of what was typed, convert each, pool the candidates, and let the LM judge.

This script, from Prototype/eval_sentences.json (kana/expected pairs):
- converts kana -> romaji (AzooKey-style spellings) and validates the
  round trip romaji -> kana == original (items that fail are dropped and
  counted: romanization ambiguities like ん before a vowel),
- injects one seeded romaji edit -> typo_kana,
- generates all 1-edit variants of the typo'd romaji -> variant kana list
  (the production candidate-generation step, capped),
- also generates variants of the CLEAN romaji (smaller cap) for the
  over-correction control: pooling must not dethrone the right winner
  when nothing was mistyped.

Output: Prototype/typo_fixture.json
"""
import json
import random
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROTO = HERE.parent

# --- kana <-> romaji (AzooKey-style spellings) ---
SINGLES = {
    "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
    "か": "ka", "き": "ki", "く": "ku", "け": "ke", "こ": "ko",
    "さ": "sa", "し": "shi", "す": "su", "せ": "se", "そ": "so",
    "た": "ta", "ち": "chi", "つ": "tsu", "て": "te", "と": "to",
    "な": "na", "に": "ni", "ぬ": "nu", "ね": "ne", "の": "no",
    "は": "ha", "ひ": "hi", "ふ": "fu", "へ": "he", "ほ": "ho",
    "ま": "ma", "み": "mi", "む": "mu", "め": "me", "も": "mo",
    "や": "ya", "ゆ": "yu", "よ": "yo",
    "ら": "ra", "り": "ri", "る": "ru", "れ": "re", "ろ": "ro",
    "わ": "wa", "を": "wo", "ん": "n",
    "が": "ga", "ぎ": "gi", "ぐ": "gu", "げ": "ge", "ご": "go",
    "ざ": "za", "じ": "ji", "ず": "zu", "ぜ": "ze", "ぞ": "zo",
    "だ": "da", "ぢ": "di", "づ": "du", "で": "de", "ど": "do",
    "ば": "ba", "び": "bi", "ぶ": "bu", "べ": "be", "ぼ": "bo",
    "ぱ": "pa", "ぴ": "pi", "ぷ": "pu", "ぺ": "pe", "ぽ": "po",
    "ぁ": "la", "ぃ": "li", "ぅ": "lu", "ぇ": "le", "ぉ": "lo",
    "ゎ": "lwa", "ー": "-",
}
KANA2ROMA = dict(SINGLES)
# Youon combos, written out explicitly (AzooKey-style spellings).
KANA2ROMA.update({
    "きゃ": "kya", "きゅ": "kyu", "きょ": "kyo",
    "しゃ": "sha", "しゅ": "shu", "しょ": "sho",
    "ちゃ": "cha", "ちゅ": "chu", "ちょ": "cho",
    "にゃ": "nya", "にゅ": "nyu", "にょ": "nyo",
    "ひゃ": "hya", "ひゅ": "hyu", "ひょ": "hyo",
    "みゃ": "mya", "みゅ": "myu", "みょ": "myo",
    "りゃ": "rya", "りゅ": "ryu", "りょ": "ryo",
    "ぎゃ": "gya", "ぎゅ": "gyu", "ぎょ": "gyo",
    "じゃ": "ja", "じゅ": "ju", "じょ": "jo",
    "ぢゃ": "dya", "ぢゅ": "dyu", "ぢょ": "dyo",
    "びゃ": "bya", "びゅ": "byu", "びょ": "byo",
    "ぴゃ": "pya", "ぴゅ": "pyu", "ぴょ": "pyo",
})


def to_hira(s: str) -> str:
    """Katakana -> hiragana (U+30A1..U+30F6 shift by -0x60; ー is shared)."""
    return "".join(chr(ord(c) - 0x60) if "ァ" <= c <= "ヶ" else c for c in s)
ROMA2KANA = {}
for kana, roma in KANA2ROMA.items():
    ROMA2KANA.setdefault(roma, kana)  # first wins; spellings are unique by construction except n


def kana_to_romaji(kana: str):
    out = []
    i = 0
    while i < len(kana):
        if kana[i] == "っ":
            # double the next token's first letter; needs a following token
            nxt = None
            if i + 2 <= len(kana) and kana[i + 1:i + 3] in KANA2ROMA:
                nxt = KANA2ROMA[kana[i + 1:i + 3]]
            elif i + 1 < len(kana) and kana[i + 1] in KANA2ROMA:
                nxt = KANA2ROMA[kana[i + 1]]
            if not nxt or nxt[0] in "aiueon-":
                return None
            out.append(nxt[0])
            i += 1
            continue
        if i + 2 <= len(kana) and kana[i:i + 2] in KANA2ROMA:
            out.append(KANA2ROMA[kana[i:i + 2]])
            i += 2
            continue
        if kana[i] in KANA2ROMA:
            out.append(KANA2ROMA[kana[i]])
            i += 1
            continue
        return None
    return "".join(out)


def romaji_to_kana(roma: str):
    out = []
    i = 0
    n = len(roma)
    while i < n:
        # geminate: same consonant twice (not nn, not a vowel) -> っ
        if i + 1 < n and roma[i] == roma[i + 1] and roma[i] not in "aiueon":
            out.append("っ")
            i += 1
            continue
        matched = None
        for ln in (3, 2, 1):
            tok = roma[i:i + ln]
            if len(tok) == ln and tok in ROMA2KANA:
                # lone "n" is ん only at end or before a consonant; the token
                # table has n->ん as fallback, but na/ni/... win by length.
                matched = (tok, ROMA2KANA[tok])
                break
        if matched is None:
            return None
        tok, kana = matched
        if tok == "n" and i + 1 < n and roma[i + 1] in "aiueoy":
            return None  # ambiguous n; would need nn/na-row token
        out.append(kana)
        i += len(tok)
    return "".join(out)


ADJ = {
    "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh",
    "u": "yihj", "i": "uojk", "o": "ipkl", "p": "ol",
    "a": "qwsz", "s": "awedzx", "d": "serfcx", "f": "drtgcv", "g": "ftyhvb",
    "h": "gyujbn", "j": "huiknm", "k": "jiolm", "l": "kop",
    "z": "asx", "x": "zsdc", "c": "xdfv", "v": "cfgb", "b": "vghn",
    "n": "bhjm", "m": "njk", "-": "p",
}


def edits(roma: str):
    subs, dels, trans, inss = [], [], [], []
    for i, ch in enumerate(roma):
        for a in ADJ.get(ch, ""):
            subs.append(roma[:i] + a + roma[i + 1:])
        dels.append(roma[:i] + roma[i + 1:])
        if i + 1 < len(roma):
            trans.append(roma[:i] + roma[i + 1] + roma[i] + roma[i + 2:])
    # Insertions: at each gap, the missed key could sit next to either
    # neighbouring key, so propose letters adjacent to both. (The first
    # version only used the following key's neighbours, which made most
    # deletion typos unrecoverable in principle.)
    for gap in range(len(roma) + 1):
        letters = set()
        if gap > 0:
            letters |= set(ADJ.get(roma[gap - 1], ""))
        if gap < len(roma):
            letters |= set(ADJ.get(roma[gap], ""))
        for a in sorted(letters):
            inss.append(roma[:gap] + a + roma[gap:])
    return subs, dels, trans, inss


def all_variants(roma: str):
    subs, dels, trans, inss = edits(roma)
    kanas = set()
    for v in subs + dels + trans + inss:
        k = romaji_to_kana(v)
        if k:
            kanas.add(k)
    kanas.discard(romaji_to_kana(roma))
    return sorted(kanas)


def variants_of(roma: str, cap: int, rng: random.Random):
    out = all_variants(roma)
    if len(out) > cap:
        rng.shuffle(out)
        out = out[:cap]
    return out


def main():
    items = json.loads((PROTO / "eval_sentences.json").read_text(encoding="utf-8"))
    rng = random.Random(20261114)
    fixture = []
    dropped_roundtrip = dropped_typo = 0
    vcounts = []
    for it in items:
        kana_orig, expected = it["kana"], it["expected"]
        # The romaji tables are hiragana-keyed. Katakana words in the eval
        # kana (メール, スーパー…) are typed as the same romaji, so work on
        # the hiragana-normalized string; the fixture keeps the original.
        kana = to_hira(kana_orig)
        roma = kana_to_romaji(kana)
        if roma is None or romaji_to_kana(roma) != kana:
            dropped_roundtrip += 1
            continue
        typo_kana = None
        typo_kind = None
        for _ in range(30):
            subs, dels, trans, inss = edits(roma)
            kind = rng.choices(["sub", "del", "trans", "ins"], weights=[40, 20, 20, 20])[0]
            pool = {"sub": subs, "del": dels, "trans": trans, "ins": inss}[kind]
            if not pool:
                continue
            cand = rng.choice(pool)
            k = romaji_to_kana(cand)
            if k and k != kana:
                typo_kana, typo_kind = k, kind
                typo_roma = cand
                break
        if typo_kana is None:
            dropped_typo += 1
            continue
        variants = variants_of(typo_roma, cap=120, rng=rng)
        clean_variants = variants_of(roma, cap=60, rng=rng)
        vcounts.append(len(variants))
        fixture.append({
            "kana": kana, "kana_orig": kana_orig, "romaji": roma, "expected": expected,
            "typo_kana": typo_kana, "typo_kind": typo_kind,
            "variants": variants, "clean_variants": clean_variants,
            "true_kana_in_variants": kana in variants,
            # Generation recall without the runtime cap: can the edit model
            # express the fix at all? (Deletions often cannot: the dropped
            # letter is not adjacent to either neighbour of the gap.)
            "true_kana_in_variants_uncapped": kana in all_variants(typo_roma),
        })
    (PROTO / "typo_fixture.json").write_text(
        json.dumps(fixture, ensure_ascii=False, indent=1), encoding="utf-8")
    import statistics
    print(f"items={len(fixture)} dropped_roundtrip={dropped_roundtrip} dropped_typo={dropped_typo}")
    print(f"variants per item: mean={statistics.mean(vcounts):.0f} max={max(vcounts)}")
    print(f"true kana recovered in variants: {sum(f['true_kana_in_variants'] for f in fixture)}/{len(fixture)}")
    kinds = {}
    for f in fixture:
        kinds[f["typo_kind"]] = kinds.get(f["typo_kind"], 0) + 1
    print("typo kinds:", kinds)


if __name__ == "__main__":
    main()
