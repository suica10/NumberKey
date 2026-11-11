#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=5a9c4f672f627c8db48241a3abc22409257f92cb
converter_dir=Vendor/AzooKeyKanaKanjiConverter
if [[ ! -d "$converter_dir/.git" ]]; then
  mkdir -p "$converter_dir"
  git -C "$converter_dir" init
  git -C "$converter_dir" remote add origin https://github.com/azooKey/AzooKeyKanaKanjiConverter.git
fi
git -C "$converter_dir" fetch --depth=1 origin "$revision"
git -C "$converter_dir" checkout --detach "$revision"
git -C "$converter_dir" submodule update --init --recursive --depth=1
test "$(git -C "$converter_dir" rev-parse HEAD)" = "$revision"
test -f "$converter_dir/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/charID.chid" || \
  test -d "$converter_dir/Sources/KanaKanjiConverterModuleWithDefaultDictionary/azooKey_dictionary_storage/Dictionary/louds"
python3 scripts/collect_licenses.py
