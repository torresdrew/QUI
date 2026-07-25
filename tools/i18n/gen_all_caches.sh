#!/usr/bin/env bash
# Regenerate core/locale/enUS.lua + enUS and all 10 locale search caches and their TOCs.
set -euo pipefail
LUA_BIN="${LUA:-lua}"
LOCALES="deDE esES esMX frFR itIT ptBR ruRU koKR zhCN zhTW"
VER="$(grep -m1 '^## Version:' QUI_OptionsSearch/QUI_OptionsSearch.toc | sed 's/## Version: //')"

# Human-readable language name for each locale's ## Notes line.
lang_name() {
  case "$1" in
    deDE) echo "German" ;;
    esES) echo "Spanish (EU)" ;;
    esMX) echo "Spanish (Latin American)" ;;
    frFR) echo "French" ;;
    itIT) echo "Italian" ;;
    ptBR) echo "Portuguese (Brazil)" ;;
    ruRU) echo "Russian" ;;
    koKR) echo "Korean" ;;
    zhCN) echo "Simplified Chinese" ;;
    zhTW) echo "Traditional Chinese" ;;
    *)    echo "$1" ;;
  esac
}
# Locale key file FIRST — the search caches embed localized strings, and this
# was historically a separate manual step everyone (human and bot) forgot:
# "enUS" below meant only the enUS SEARCH CACHE, never core/locale/enUS.lua.
"${LUA_BIN}" tools/i18n/extract_strings.lua                      # core/locale/enUS.lua
"${LUA_BIN}" tools/generate_search_cache.lua                     # enUS (existing addon)
for loc in $LOCALES; do
  dir="QUI_OptionsSearch_${loc}"
  mkdir -p "$dir"
  "${LUA_BIN}" tools/generate_search_cache.lua "$loc"
  # Combined per-locale addon TOC: UI-string overlay (bootstrap.lua + <loc>.lua)
  # + generated search index. Keep in sync with the committed format — a bare
  # search-only TOC (no overlay files, RequiredDeps on QUI_Options) drops the
  # translations at login AND drags the ~2.9 MB options engine into the login
  # path. See the in-file comment block below for the load-order contract.
  cat > "${dir}/${dir}.toc" <<EOF
## Interface: 120100
## Title: |cFF30D1FFQUI|r Locale + Options Search ${loc}
## IconTexture: Interface\\AddOns\\QUI\\assets\\QUI
## Notes: $(lang_name "$loc") translations + settings search index for QUI
## Author: Zol
## Version: ${VER}
## Category: User Interface
## Group: QUI
## LoadOnDemand: 1

# Combined per-locale addon: UI-string overlay + generated settings search
# index — ONE folder per locale instead of two.
#
# Loaded SYNCHRONOUSLY mid-QUI-load by core/locale/load_overlay.lua so the
# overlay's ns.LocaleData.active lands before core/locale/locale.lua captures
# it. NO RequiredDeps on purpose: a QUI_Options dep would drag the ~2.9 MB
# options engine into the login path (bootstrap.lua hard-errors if the QUI
# core is somehow absent). search_cache.lua's tail self-apply no-ops at login
# (QUI_Options not loaded yet); the index parks on the shared ns and
# GUI:EnsureSearchCacheLoaded applies it on first search.
bootstrap.lua
${loc}.lua
search_cache.lua
EOF
done
echo "generated enUS + ${LOCALES}"
