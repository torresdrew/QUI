#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
[ -f QUI.toc ] || { echo "ERROR: run from the QUI repo root" >&2; exit 1; }

# NOTE: this script is HALF the apply. The generated tools/suite_split/QUI.toc
# and tools/suite_split/QUI_Options.toc must be copied over the live files
# manually (plan Task 4).

mkdir -p QUI_ActionBars
if [ -d modules/actionbars ]; then
  [ -e QUI_ActionBars/actionbars ] && { echo "ERROR: QUI_ActionBars/actionbars exists" >&2; exit 1; }
  git mv modules/actionbars QUI_ActionBars/actionbars
  echo "moved: modules/actionbars -> QUI_ActionBars/actionbars"
else
  echo "skip: modules/actionbars already moved"
fi
cp tools/suite_split/QUI_ActionBars/QUI_ActionBars.toc QUI_ActionBars/
cp core/templates/subaddon_bootstrap.lua QUI_ActionBars/bootstrap.lua

mkdir -p QUI_CDM
if [ -d modules/cdm ]; then
  [ -e QUI_CDM/cdm ] && { echo "ERROR: QUI_CDM/cdm exists" >&2; exit 1; }
  git mv modules/cdm QUI_CDM/cdm
  echo "moved: modules/cdm -> QUI_CDM/cdm"
else
  echo "skip: modules/cdm already moved"
fi
cp tools/suite_split/QUI_CDM/QUI_CDM.toc QUI_CDM/
cp core/templates/subaddon_bootstrap.lua QUI_CDM/bootstrap.lua

mkdir -p QUI_Chat
if [ -d modules/chat ]; then
  [ -e QUI_Chat/chat ] && { echo "ERROR: QUI_Chat/chat exists" >&2; exit 1; }
  git mv modules/chat QUI_Chat/chat
  echo "moved: modules/chat -> QUI_Chat/chat"
else
  echo "skip: modules/chat already moved"
fi
cp tools/suite_split/QUI_Chat/QUI_Chat.toc QUI_Chat/
cp core/templates/subaddon_bootstrap.lua QUI_Chat/bootstrap.lua

mkdir -p QUI_GroupFrames
if [ -d modules/groupframes ]; then
  [ -e QUI_GroupFrames/groupframes ] && { echo "ERROR: QUI_GroupFrames/groupframes exists" >&2; exit 1; }
  git mv modules/groupframes QUI_GroupFrames/groupframes
  echo "moved: modules/groupframes -> QUI_GroupFrames/groupframes"
else
  echo "skip: modules/groupframes already moved"
fi
cp tools/suite_split/QUI_GroupFrames/QUI_GroupFrames.toc QUI_GroupFrames/
cp core/templates/subaddon_bootstrap.lua QUI_GroupFrames/bootstrap.lua

mkdir -p QUI_ResourceBars
if [ -d modules/resourcebars ]; then
  [ -e QUI_ResourceBars/resourcebars ] && { echo "ERROR: QUI_ResourceBars/resourcebars exists" >&2; exit 1; }
  git mv modules/resourcebars QUI_ResourceBars/resourcebars
  echo "moved: modules/resourcebars -> QUI_ResourceBars/resourcebars"
else
  echo "skip: modules/resourcebars already moved"
fi
cp tools/suite_split/QUI_ResourceBars/QUI_ResourceBars.toc QUI_ResourceBars/
cp core/templates/subaddon_bootstrap.lua QUI_ResourceBars/bootstrap.lua

mkdir -p QUI_UnitFrames
if [ -d modules/unitframes ]; then
  [ -e QUI_UnitFrames/unitframes ] && { echo "ERROR: QUI_UnitFrames/unitframes exists" >&2; exit 1; }
  git mv modules/unitframes QUI_UnitFrames/unitframes
  echo "moved: modules/unitframes -> QUI_UnitFrames/unitframes"
else
  echo "skip: modules/unitframes already moved"
fi
cp tools/suite_split/QUI_UnitFrames/QUI_UnitFrames.toc QUI_UnitFrames/
cp core/templates/subaddon_bootstrap.lua QUI_UnitFrames/bootstrap.lua

mkdir -p QUI_DamageMeter
if [ -d modules/damage_meter ]; then
  [ -e QUI_DamageMeter/damage_meter ] && { echo "ERROR: QUI_DamageMeter/damage_meter exists" >&2; exit 1; }
  git mv modules/damage_meter QUI_DamageMeter/damage_meter
  echo "moved: modules/damage_meter -> QUI_DamageMeter/damage_meter"
else
  echo "skip: modules/damage_meter already moved"
fi
cp tools/suite_split/QUI_DamageMeter/QUI_DamageMeter.toc QUI_DamageMeter/
cp core/templates/subaddon_bootstrap.lua QUI_DamageMeter/bootstrap.lua
