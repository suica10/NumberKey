#!/usr/bin/env python3
"""Build Keyboard/emoji_data.txt from the Unicode emoji test file.

Source: https://www.unicode.org/Public/emoji/latest/emoji-test.txt
(Unicode license; data file listing fully-qualified emoji by group).

Output: one line per category, "label<TAB>emoji1 emoji2 ...".
Only fully-qualified emoji are kept; the Component group and all
skin-tone variants are excluded (the base forms remain).
"""
import sys

GROUP_LABELS = {
    "Smileys & Emotion": "顔",
    "People & Body": "人",
    "Animals & Nature": "動物",
    "Food & Drink": "食べ物",
    "Activities": "活動",
    "Travel & Places": "旅行",
    "Objects": "物",
    "Symbols": "記号",
    "Flags": "旗",
}
SKIN_TONES = {"\U0001F3FB", "\U0001F3FC", "\U0001F3FD", "\U0001F3FE", "\U0001F3FF"}


def main(source_path: str, out_path: str) -> None:
    groups: dict[str, list[str]] = {}
    current_group = None
    with open(source_path, encoding="utf-8") as source:
        for line in source:
            if line.startswith("# group:"):
                current_group = line.split(":", 1)[1].strip()
                continue
            if not line.strip() or line.startswith("#"):
                continue
            if current_group not in GROUP_LABELS:
                continue
            parts = line.split(";")
            if len(parts) < 2 or parts[1].split("#")[0].strip() != "fully-qualified":
                continue
            codepoints = parts[0].strip().split()
            emoji = "".join(chr(int(cp, 16)) for cp in codepoints)
            if any(tone in emoji for tone in SKIN_TONES):
                continue
            groups.setdefault(current_group, []).append(emoji)
    with open(out_path, "w", encoding="utf-8") as out:
        total = 0
        for group, label in GROUP_LABELS.items():
            emojis = groups.get(group, [])
            total += len(emojis)
            out.write(label + "\t" + " ".join(emojis) + "\n")
            print(f"{label}: {len(emojis)}")
    print(f"total: {total}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
