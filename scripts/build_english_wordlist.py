#!/usr/bin/env python3
"""Build Keyboard/english_words.txt from the AOSP LatinIME English wordlist.

Source: platform/packages/inputmethods/LatinIME dictionaries/en_wordlist.combined
(tag android-11.0.0_r45, Apache License 2.0). The .combined file is gzipped
text with lines like:  word=the,f=222,flags=,originalFreq=222

Output: TSV "word<TAB>freq" sorted by word, one per line. Only plain
lowercase words (internal apostrophes allowed) at or above MIN_FREQ are
kept, so the bundled file stays small enough for a keyboard extension.
"""
import re
import sys

MIN_FREQ = 35
WORD_RE = re.compile(r"^[a-z]+(?:'[a-z]+)?$")


def main(source_path: str, out_path: str) -> None:
    words: dict[str, int] = {}
    with open(source_path, encoding="utf-8", errors="replace") as source:
        for line in source:
            if not line.startswith(" word="):
                continue
            fields = dict(
                part.split("=", 1) for part in line.strip().split(",") if "=" in part
            )
            word = fields.get("word", "")
            flags = fields.get("flags", "")
            try:
                freq = int(fields.get("f", "0"))
            except ValueError:
                continue
            if freq < MIN_FREQ or "offensive" in flags or not WORD_RE.match(word):
                continue
            if freq > words.get(word, -1):
                words[word] = freq
    with open(out_path, "w", encoding="utf-8") as out:
        for word in sorted(words):
            out.write(f"{word}\t{words[word]}\n")
    print(f"wrote {len(words)} words to {out_path}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
