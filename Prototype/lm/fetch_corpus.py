#!/usr/bin/env python3
"""Fetch the Tatoeba Japanese sentence export (CC BY 2.0 FR) and extract
plain sentence text, one sentence per line, into corpus.txt."""
import bz2
import sys
import urllib.request
from pathlib import Path

URL = "https://downloads.tatoeba.org/exports/per_language/jpn/jpn_sentences.tsv.bz2"
HERE = Path(__file__).resolve().parent


def main() -> None:
    raw = HERE / "jpn_sentences.tsv.bz2"
    if not raw.exists():
        print(f"downloading {URL}", flush=True)
        urllib.request.urlretrieve(URL, raw)
    out = HERE / "corpus.txt"
    n = 0
    with bz2.open(raw, "rt", encoding="utf-8") as f, out.open("w", encoding="utf-8") as w:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3:
                text = parts[2].strip()
                if text:
                    w.write(text + "\n")
                    n += 1
    print(f"wrote {n} sentences to {out}")


if __name__ == "__main__":
    sys.exit(main())
