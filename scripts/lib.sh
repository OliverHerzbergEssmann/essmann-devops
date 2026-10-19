# Gemeinsame Helfer für die Skripte in scripts/. Einbinden mit: source "$(dirname "$0")/../lib.sh"
# (lokal) bzw. per Anhängen durch ops (auf dem Server liegt nur die eine Datei).

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_FAIL=$'\033[1;31m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_WARN=''; C_FAIL=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '%sWARNUNG: %s%s\n' "$C_WARN" "$1" "$C_END" >&2; }
fail() { printf '\n%sFEHLER: %s%s\n' "$C_FAIL" "$1" "$C_END" >&2; exit 1; }
ok() { printf '\n%s%s%s\n' "$C_OK" "$1" "$C_END"; }

# write_marker <datei> key=value ...  schreibt die Marker-Datei neu (Zeit und Benutzer kommen dazu)
write_marker() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  {
    printf 'at=%s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'by=%s\n' "$(whoami)"
    for kv in "$@"; do printf '%s\n' "$kv"; done
  } > "$file"
}
