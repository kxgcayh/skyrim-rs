#!/usr/bin/env bash
# macOS counterpart of package.ps1: cross-builds release and writes dist/skyrim-runtime-extender-<version>.zip.
# package.ps1 stays the single source: the package list, the shipped profiles, the cargo packages and the
# version rule are read from it on every run, and anything in it this script cannot read stops the build.
# Fork-only tooling: upstream builds on Windows and does not carry this file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PS1=scripts/package.ps1
die() { echo "package-macos: $*" >&2; exit 1; }

# --- version: upstream's rule, counted up to the upstream commit this branch is on ---------------------
# Commits only this fork carries (this script, build-macos.sh, local fixes) must not raise the number,
# or a local build would claim an upstream release it is not. They show as -fork.<n> instead.
UPSTREAM="${UPSTREAM_REF:-upstream/master}"
git rev-parse -q --verify "$UPSTREAM" >/dev/null || die "no $UPSTREAM ref (git remote add upstream https://github.com/TwistedModding/skyrim-rs.git; git fetch upstream), or set UPSTREAM_REF"
base="$(git merge-base HEAD "$UPSTREAM")"
RELEASE="$(sed -n 's/^\$Release = "\(.*\)"\r*$/\1/p' "$PS1")"
[ -n "$RELEASE" ] || die "no \$Release in $PS1"
since="$(git log -1 --format=%H -G '^\$Release = ' "$base" -- "$PS1")"
[ -n "$since" ] || die "git log found no commit setting \$Release"
version="$RELEASE.$(git rev-list --count "$since..$base")"
ahead="$(git rev-list --count "$base..HEAD")"
[ "$ahead" = 0 ] || version="$version-fork.$ahead"
[ -z "$(git status --porcelain)" ] || version="$version-dirty"
export SKYRIM_RS_VERSION="$version"

# --- notices: package.ps1 runs notices.ps1 -Check (cargo-about through cmd, Windows only) -------------
# THIRD-PARTY-NOTICES.txt is upstream's, checked by upstream for upstream's Cargo.lock. It still holds
# when this tree resolves exactly the same crates; otherwise it has to be regenerated with notices.ps1.
crates() { awk '/^name = /{n=$3} /^version = /{print n" "$3}' | tr -d '"' | sort -u; }
lock_diff="$(diff <(git show "$base:Cargo.lock" | crates) <(crates < Cargo.lock) || true)"
[ -z "$lock_diff" ] || die "Cargo.lock resolves other crates than upstream's, so THIRD-PARTY-NOTICES.txt may be stale; regenerate it with scripts/notices.ps1 (cargo-about) first:
$lock_diff"
grep -q 'notices.ps1" -Check' "$PS1" || die "$PS1 no longer calls notices.ps1 -Check; review this script's notices gate"

# --- cargo packages, from package.ps1's cargo build line ---------------------------------------------
packages=()
while read -r p; do packages+=(-p "$p"); done < <(grep -E '^cargo build ' "$PS1" | grep -oE ' -p [A-Za-z0-9_-]+' | awk '{print $2}')
[ "${#packages[@]}" -gt 0 ] || die "no cargo build -p packages in $PS1"
scripts/build-macos.sh --release "${packages[@]}"
R="target/x86_64-pc-windows-msvc/release"

# --- package entries, from package.ps1's $entries table and its profile loop -------------------------
# package.ps1 paths: $release\<file> is the build output, $Root\<path> the repository.
path_of() {
  local v="$1"
  v="${v//\$release\\/$R/}"
  v="${v//\$Root\\/}"
  v="${v//\\//}"
  case "$v" in *'$'*) die "unreadable source path in $PS1: $1";; esac
  printf '%s' "$v"
}
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
count=0
put() {
  [ -f "$2" ] || die "missing $2 (for $1)"
  mkdir -p "$STAGE/$(dirname "$1")"; cp "$2" "$STAGE/$1"; count=$((count + 1))
}
table="$(sed -n '/^\$entries = \[ordered\]@{/,/^}/p' "$PS1" | sed '1d;$d' | tr -d '\r')"
[ -n "$table" ] || die "no \$entries table in $PS1"
while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*\"([^\"]+)\"[[:space:]]*=[[:space:]]*\"([^\"]+)\"[[:space:]]*$ ]] || die "unreadable \$entries line: $line"
  key="${BASH_REMATCH[1]}"; src="$(path_of "${BASH_REMATCH[2]}")"
  put "$key" "$src"
done <<< "$table"

profiles="$(sed -n 's/^\$ShippedProfiles = @(\(.*\))\r*$/\1/p' "$PS1" | tr ',' ' ' | tr -d '"')"
[ -n "$profiles" ] || die "no \$ShippedProfiles in $PS1"
loop="$(grep -E '^foreach \(\$name in \$ShippedProfiles\)' "$PS1" | tr -d '\r')"
[[ "$loop" =~ \$entries\[\"([^\"]+)\"\][[:space:]]*=[[:space:]]*\"([^\"]+)\" ]] || die "unreadable profile loop in $PS1"
key_t="${BASH_REMATCH[1]}"; src_t="${BASH_REMATCH[2]}"
for name in $profiles; do
  src="$(path_of "${src_t//\$name/$name}")"
  put "${key_t//\$name/$name}" "$src"
done

# Any other way package.ps1 adds an entry is one this script does not know.
other="$(grep -n '\$entries\[' "$PS1" | grep -v 'foreach (\$name in \$ShippedProfiles)' || true)"
[ -z "$other" ] || die "$PS1 adds entries in a way this script does not read: $other"

mkdir -p dist
out="$ROOT/dist/skyrim-runtime-extender-$version.zip"
rm -f "$out"
(cd "$STAGE" && zip -q -r -X "$out" .)
echo "packaged $count files" >&2

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
