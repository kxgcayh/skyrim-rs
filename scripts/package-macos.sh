#!/usr/bin/env bash
# macOS counterpart of package.ps1: cross-builds release and writes dist/skyrim-runtime-extender-<version>.zip.
# Skips notices.ps1 -Check (PowerShell only); run it on Windows before publishing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RELEASE="$(sed -n 's/^\$Release = "\(.*\)"$/\1/p' scripts/package.ps1)"
since="$(git log -1 --format=%H -G '^\$Release = ' -- scripts/package.ps1)"
[ -n "$since" ] || { echo "git log failed" >&2; exit 1; }
version="$RELEASE.$(git rev-list --count "$since..HEAD")"
[ -z "$(git status --porcelain)" ] || version="$version-dirty"
export SKYRIM_RS_VERSION="$version"

scripts/build-macos.sh --release -p host -p timing -p standalone
R="target/x86_64-pc-windows-msvc/release"

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
put() { mkdir -p "$STAGE/$(dirname "$1")"; cp "$2" "$STAGE/$1"; }
put "SKSE/Plugins/skyrim_runtime_extender.dll" "$R/skyrim_runtime_extender.dll"
put "SKSE/Plugins/!!!skyrim-runtime-extender-timing.dll" "$R/skyrim_runtime_extender_timing.dll"
put "optional-standalone/dinput8.dll" "$R/dinput8.dll"
put "optional-standalone/README.md" crates/standalone/README.md
put "README.md" crates/host/README.md
put "LICENSE.txt" LICENSE
put "THIRD-PARTY-NOTICES.txt" THIRD-PARTY-NOTICES.txt
# Keep in sync with $ShippedProfiles in package.ps1.
for p in $(sed -n 's/^\$ShippedProfiles = @(\(.*\))$/\1/p' scripts/package.ps1 | tr ',' ' ' | tr -d '"'); do
  put "SKSE/Plugins/skyrim-runtime-extender/profiles/$p.profile" "crates/host/profiles/$p.profile"
done

mkdir -p dist
out="$ROOT/dist/skyrim-runtime-extender-$version.zip"
rm -f "$out"
(cd "$STAGE" && zip -q -r -X "$out" .)

# MO2 takes an installed mod's version from <archive>.meta next to the archive, not from a meta.ini
# inside it (installationmanager.cpp: it copies the download .meta over the bundled one). Same layout
# as skyrim-workspace/tools/mod-release/release.py download_meta: MO2's key order, CRLF, version
# padded to four parts. Install with "Install a new mod from an archive" on the zip in dist/, or
# copy both files into MO2's downloads folder; dragging only the zip gives MO2's blank .meta.
meta_version="$version"
if [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,3}$ ]]; then
  IFS=. read -r -a parts <<< "$version"
  while [ "${#parts[@]}" -lt 4 ]; do parts+=(0); done
  meta_version="$(IFS=.; echo "${parts[*]:0:4}")"
fi
{
  printf '%s\r\n' "[General]" "gameName=SkyrimSE" "modID=0" "modName=Skyrim Runtime Extender" \
    "version=$meta_version" "newestVersion=$meta_version" "installed=false" "fileID=0" "url=" "name=" \
    "description=" 'fileTime=@DateTime(\0\0\0\x10\0\x80\0\0\0\0\0\0\0\xff\xff\xff\xff\0)' \
    "fileCategory=1" "category=39" "repository=" 'userData=@Variant(\0\0\0\b\0\0\0\0)' \
    "author=" "uploader=" "uploaderUrl=" "uninstalled=false" "paused=false" "removed=false"
} > "$out.meta"
echo "$out"
