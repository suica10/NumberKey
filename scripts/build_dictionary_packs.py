#!/usr/bin/env python3
"""種リスト (docs/*-dictionary-seed.md) から辞書パックのデータファイルを生成する。

出力 (Keyboard/ 配下、キーボード拡張に同梱される):
  dictionary_industrial.tsv / dictionary_anime.tsv
  dictionary_oshikatsu_common.tsv / dictionary_oshikatsu_male.tsv
  dictionary_oshikatsu_female.tsv

形式: 1行 = 読み<TAB>表記。
メモ欄に「要確認」「確認待ち」「未確認」を含む行は、読みや表記が未確定なので
収録しない (除外した行は標準出力に列挙する)。
「販売時に要再確認」は鮮度フラグであり、確定情報なので収録対象に含める。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ROOT / "docs"
OUT = ROOT / "Keyboard"

SKIP_MARKERS = ("要確認", "確認待ち", "未確認")


def parse_rows(lines):
    """Markdown テーブル行を (読み, 表記, メモ) のリストにする。"""
    rows = []
    for line in lines:
        line = line.strip()
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 2:
            continue
        reading, surface = cells[0], cells[1]
        memo = cells[2] if len(cells) > 2 else ""
        if not reading or not surface:
            continue
        if "読み" in reading:  # ヘッダ行
            continue
        if set(reading) <= set("-: "):  # 罫線行
            continue
        rows.append((reading, surface, memo))
    return rows


def emit(name, rows):
    seen = set()
    kept, skipped = [], []
    for reading, surface, memo in rows:
        if any(m in memo for m in SKIP_MARKERS):
            skipped.append((reading, surface, memo))
            continue
        key = (reading, surface)
        if key in seen:
            continue
        seen.add(key)
        kept.append(key)
    path = OUT / f"dictionary_{name}.tsv"
    with path.open("w", encoding="utf-8") as fh:
        for reading, surface in kept:
            fh.write(f"{reading}\t{surface}\n")
    print(f"{path.name}: {len(kept)} 件 (除外 {len(skipped)} 件)")
    for reading, surface, memo in skipped:
        print(f"  除外: {reading} -> {surface} ({memo})")
    return len(kept)


def section(lines, start_pred, stop_pred):
    out, active = [], False
    for line in lines:
        if not active and start_pred(line):
            active = True
            continue
        if active and stop_pred(line):
            break
        if active:
            out.append(line)
    return out


def main():
    total = 0

    # 工業: 「## 1.」から「## 検証待ちメモ」の手前まで
    lines = (DOCS / "industrial-dictionary-seed.md").read_text(encoding="utf-8").splitlines()
    body = section(lines,
                   lambda l: l.startswith("## 1."),
                   lambda l: l.startswith("## 検証待ち"))
    total += emit("industrial", parse_rows(body))

    # アニメ: 「## 種リスト」から「## 収録しなかったもの」の手前まで
    lines = (DOCS / "anime-dictionary-seed.md").read_text(encoding="utf-8").splitlines()
    body = section(lines,
                   lambda l: l.startswith("## 種リスト"),
                   lambda l: l.startswith("## 収録しなかったもの"))
    total += emit("anime", parse_rows(body))

    # 推し活: 「## 種リスト」以降をユニット見出しで3分割
    lines = (DOCS / "oshikatsu-dictionary-seed.md").read_text(encoding="utf-8").splitlines()
    body = section(lines,
                   lambda l: l.startswith("## 種リスト"),
                   lambda l: l.startswith("## 収録しなかったもの"))
    units = {"oshikatsu_common": [], "oshikatsu_male": [], "oshikatsu_female": []}
    current = None
    for line in body:
        if line.startswith("## ユニット1"):
            current = "oshikatsu_common"
            continue
        if line.startswith("## ユニット2"):
            current = "oshikatsu_male"
            continue
        if line.startswith("## ユニット3"):
            current = "oshikatsu_female"
            continue
        if current:
            units[current].append(line)
    for name, unit_lines in units.items():
        total += emit(name, parse_rows(unit_lines))

    print(f"合計: {total} 件")
    return 0


if __name__ == "__main__":
    sys.exit(main())
