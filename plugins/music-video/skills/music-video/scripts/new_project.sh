#!/usr/bin/env bash
# new_project.sh <project-dir> — scaffold a music-video project from this skill's template.
# Layout: lyrics.json cues.json music/ images/ clips/ sfx/ at the root; the renderer lives in build/.
# Never overwrites existing files, so it is safe to rerun. Put the project on a volume with room (frames are
# ~150 KB each, 5,400 per 3 min).
set -euo pipefail
[[ $# -eq 1 ]] || { echo "usage: $0 <project-dir>" >&2; exit 64; }
dir="$1"; skill="$(cd "$(dirname "$0")/.." && pwd)"; t="$skill/template"

# copy_missing SRC DEST: copy a file, or every file of a directory tree, where DEST has none yet.
# (Not cp -n, whose exit status and warnings differ across GNU coreutils versions and BSD.)
copy_missing() {
  local src="$1" dest="$2" rel
  if [[ -d "$src" ]]; then
    while IFS= read -r rel; do
      rel="${rel#"$src"/}"
      [[ -e "$dest/$rel" ]] && continue
      mkdir -p "$(dirname "$dest/$rel")"
      cp "$src/$rel" "$dest/$rel"
    done < <(find "$src" -type f)
  elif [[ ! -e "$dest" ]]; then
    cp "$src" "$dest"
  fi
}

mkdir -p "$dir"/{music,images,clips,sfx,build/out}
copy_missing "$t/lyrics.example.json" "$dir/lyrics.json"
copy_missing "$t/cues.example.json" "$dir/cues.json"
copy_missing "$t/images/prompts.example.json" "$dir/images/prompts.json"
copy_missing "$t/clips/jobs.example.json" "$dir/clips/jobs.json"
for f in studio.html render.mjs package.json; do copy_missing "$t/$f" "$dir/build/$f"; done
copy_missing "$t/src" "$dir/build/src"
copy_missing "$t/fonts" "$dir/build/fonts"   # with their license, fonts/OFL.txt
(cd "$dir/build" && npm install --no-audit --no-fund --silent)
echo "scaffolded $dir"
echo "next: edit $dir/lyrics.json, then from $dir: python3 $skill/scripts/gen_music.py"
