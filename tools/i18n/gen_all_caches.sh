#!/usr/bin/env bash
# Regenerate core/locale/enUS.lua + enUS and all 10 locale search caches and their TOCs.
set -euo pipefail
LUA_BIN="${LUA:-lua}"
LOCALES="deDE esES esMX frFR itIT ptBR ruRU koKR zhCN zhTW"
VER="$(grep -m1 '^## Version:' QUI_OptionsSearch/QUI_OptionsSearch.toc | sed 's/## Version: //')"
# Locale key file FIRST — the search caches embed localized strings, and this
# was historically a separate manual step everyone (human and bot) forgot:
# "enUS" below meant only the enUS SEARCH CACHE, never core/locale/enUS.lua.
"${LUA_BIN}" tools/i18n/extract_strings.lua                      # core/locale/enUS.lua
"${LUA_BIN}" tools/generate_search_cache.lua                     # enUS (existing addon)
for loc in $LOCALES; do
  dir="QUI_OptionsSearch_${loc}"
  mkdir -p "$dir"
  "${LUA_BIN}" tools/generate_search_cache.lua "$loc"
  cat > "${dir}/${dir}.toc" <<EOF
## Interface: 120100
## Title: |cFF30D1FFQUI|r Options Search (${loc})
## IconTexture: Interface\\AddOns\\QUI\\assets\\QUI
## Notes: Load-on-demand localized settings search index for QUI (${loc})
## Author: Zol
## Version: ${VER}
## Category: User Interface
## Group: QUI
## RequiredDeps: QUI, QUI_Options
## LoadOnDemand: 1

search_cache.lua
EOF
done
echo "generated enUS + ${LOCALES}"
