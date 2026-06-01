#!/usr/bin/env bash

# Shared helpers for anonymously discovering public GitHub release metadata.
#
# Design contract:
# - Callers pass GitHub repository slugs as owner/repo.
# - Tag discovery uses `git ls-remote` against the public HTTPS remote.
# - Release timestamps and asset URLs come from public GitHub release pages,
#   because release artifacts are not stored in the git object database.
# - Helpers print data to stdout and reserve stderr for diagnostics.

github_public_repo_url() {
  printf 'https://github.com/%s.git\n' "$1"
}

github_latest_tag_matching() {
  local repo="$1"
  local tag_regex="$2"

  GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "$(github_public_repo_url "$repo")" |
    python3 -c '
import re
import sys

pattern = re.compile(sys.argv[1])
tags = []

for line in sys.stdin:
    parts = line.strip().split()
    if len(parts) != 2:
        continue
    ref = parts[1]
    if not ref.startswith("refs/tags/"):
        continue
    tag = ref[len("refs/tags/"):]
    if pattern.search(tag):
        tags.append(tag)

if not tags:
    raise SystemExit(f"No tags matched pattern: {pattern.pattern}")

def version_key(value: str):
    pieces = []
    for token in re.split(r"([0-9]+)", value):
        if not token:
            continue
        pieces.append(int(token) if token.isdigit() else token.lower())
    return pieces

print(sorted(tags, key=version_key)[-1])
' "$tag_regex"
}

github_release_published_at() {
  local repo="$1"
  local tag="$2"

  curl -fsSL "https://github.com/${repo}/releases/tag/${tag}" |
    python3 -c '
import html
import re
import sys

page = html.unescape(sys.stdin.read())
match = re.search(r"datetime=\"([^\"]+)\"", page)
if not match:
    raise SystemExit("Could not parse release timestamp")
print(match.group(1))
'
}

github_release_asset_info() {
  local repo="$1"
  local tag="$2"
  local asset_regex="$3"
  local pick_mode="${4:-first}"

  curl -fsSL "https://github.com/${repo}/releases/expanded_assets/${tag}" |
    python3 -c '
import html
import re
import sys
import urllib.parse

repo = sys.argv[1]
tag = sys.argv[2]
asset_pattern = re.compile(sys.argv[3])
pick_mode = sys.argv[4]
page = html.unescape(sys.stdin.read())
href_pattern = re.compile(
    r"href=\"(/%s/releases/download/%s/[^\"]+)\"" % (
        re.escape(repo),
        re.escape(tag),
    )
)

candidates = []
seen = set()
for href in href_pattern.findall(page):
    url = urllib.parse.urljoin("https://github.com", href)
    name = urllib.parse.unquote(url.rsplit("/", 1)[-1])
    if name in seen:
        continue
    seen.add(name)
    if asset_pattern.match(name):
        candidates.append((name, url))

if not candidates:
    raise SystemExit(f"No assets matched pattern: {asset_pattern.pattern}")

candidates.sort()
name, url = candidates[-1] if pick_mode == "last" else candidates[0]
print(f"{url}\t{name}")
' "$repo" "$tag" "$asset_regex" "$pick_mode"
}

github_latest_release_asset_info() {
  local repo="$1"
  local tag_regex="$2"
  local asset_regex="$3"
  local pick_mode="${4:-first}"
  local tag
  local published_at
  local asset_url
  local asset_name

  tag="$(github_latest_tag_matching "$repo" "$tag_regex")" || return 1
  published_at="$(github_release_published_at "$repo" "$tag")" || return 1
  IFS=$'\t' read -r asset_url asset_name \
    < <(github_release_asset_info "$repo" "$tag" "$asset_regex" "$pick_mode") \
    || return 1

  printf '%s\t%s\t%s\t%s\t%s\n' "$tag" "$published_at" "$tag" "$asset_url" "$asset_name"
}