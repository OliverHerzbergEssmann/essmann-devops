#!/usr/bin/env bash
#
# Räumt alte Logfiles, alte Exporte und den alten Google-Feed einer Shop-Installation auf.
# Läuft AUF dem Zielsystem, gestartet per `ops shop:cleanup <ziel>`, das diese Datei bei jedem Aufruf hochlädt.
#
# Was als alt gilt, entscheidet allein die Änderungszeit (älter als DAYS Tage). Das schützt auch den aktuellen
# Google-Feed: den erzeugt der Cronjob des Produktexports täglich neu, er ist nie älter als ein Tag.
#
# Umgebung (setzt ops): ROOT, PHP (PHP-Aufruf als der Benutzer, dem var/ gehört), MARKER_DIR,
#   DAYS (Vorgabe 7), DRY_RUN (0/1), FEED_PATTERN (Vorgabe *google*)
set -euo pipefail

ROOT="${ROOT:-/var/www/shopware}"
PHP="${PHP:-php}"
MARKER_DIR="${MARKER_DIR:-$HOME/.essmann-ops/shop}"
DAYS="${DAYS:-7}"
DRY_RUN="${DRY_RUN:-0}"
FEED_PATTERN="${FEED_PATTERN:-*google*}"

if [ -t 1 ]; then C_STEP=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_OK=$'\033[1;32m'; C_END=$'\033[0m'; else C_STEP=''; C_WARN=''; C_OK=''; C_END=''; fi
step() { printf '\n%s==> %s%s\n' "$C_STEP" "$1" "$C_END"; }
note() { printf '    %s\n' "$1"; }
warn() { printf '%sWARNUNG: %s%s\n' "$C_WARN" "$1" "$C_END" >&2; }
fail() { printf '\n\033[1;31mFEHLER: %s\033[0m\n' "$1" >&2; exit 1; }

case "$DAYS" in ''|*[!0-9]*) fail "DAYS muss eine ganze Zahl sein: $DAYS" ;; esac
[ -d "$ROOT" ] || fail "Wurzel fehlt: $ROOT"
cd "$ROOT"
MINUTES=$((DAYS * 1440))
TOTAL_FILES=0
TOTAL_BYTES=0

# remove_old <titel> <ordner> <find-Muster|-> [find-Muster der Ausnahmen|-]
# Listet Dateien in <ordner> (rekursiv), die älter als DAYS Tage sind, und löscht sie, außer im Trockenlauf.
# Beim Feed wird das Namensmuster als Filter benutzt, bei Logs und Exporten steht "-" für "alle".
remove_old() {
  local title="$1" dir="$2" include="$3" exclude="$4"
  local -a args=("$dir" -type f -mmin "+$MINUTES")
  [ "$include" = "-" ] || args+=(-iname "$include")
  [ "$exclude" = "-" ] || args+=(! -iname "$exclude")

  step "$title (älter als $DAYS Tage)"
  if [ ! -d "$dir" ]; then note "Ordner fehlt, übersprungen: $dir"; return 0; fi

  local list
  list=$(find "${args[@]}" 2>/dev/null | sort || true)
  if [ -z "$list" ]; then note "Nichts zu löschen."; return 0; fi

  local count=0 bytes=0 size f
  while IFS= read -r f; do
    size=$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)
    count=$((count + 1)); bytes=$((bytes + size))
    note "$(printf '%9s KB  %s' "$((size / 1024))" "${f#"$ROOT"/}")"
  done <<< "$list"

  if [ "$DRY_RUN" = "1" ]; then
    note "Trockenlauf: $count Dateien, $((bytes / 1024 / 1024)) MB würden gelöscht."
  else
    local left
    while IFS= read -r f; do rm -f -- "$f" 2>/dev/null || true; done <<< "$list"
    left=$(while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done <<< "$list" || true)
    if [ -n "$left" ]; then
      # Dateien, die dem Anwendungsbenutzer gehören (Stage: www-data): löschen mit dem PHP dieses Benutzers
      note "Kein Schreibrecht auf $(printf '%s\n' "$left" | wc -l | tr -d ' ') Dateien, lösche sie als Besitzer von var/."
      # shellcheck disable=SC2086 # $PHP ist bewusst ein Befehl mit Argumenten (zum Beispiel "sudo -u www-data php")
      printf '%s\n' "$left" | $PHP -r 'array_map(unlink(...), array_filter(explode("\n", stream_get_contents(STDIN))));' || true
      left=$(while IFS= read -r f; do [ -e "$f" ] && printf '%s\n' "$f"; done <<< "$left" || true)
      [ -z "$left" ] || fail "Nicht gelöscht: $(printf '%s\n' "$left" | head -3 | tr '\n' ' ')"
    fi
    note "Gelöscht: $count Dateien, $((bytes / 1024 / 1024)) MB."
  fi
  TOTAL_FILES=$((TOTAL_FILES + count)); TOTAL_BYTES=$((TOTAL_BYTES + bytes))
}

# Der Feed wird zuerst entfernt und aus der Liste der Exporte ausgenommen, damit nichts doppelt zählt.
remove_old "Google-Feed (alt)" "$ROOT/files/export" "$FEED_PATTERN" "-"
remove_old "Alte Exporte" "$ROOT/files/export" "-" "$FEED_PATTERN"
remove_old "Alte Logfiles" "$ROOT/var/log" "*.log*" "-"

step "Abgelaufene Import-/Export-Dateien (Shopware, mit Datenbankeinträgen)"
if [ ! -f bin/console ]; then
  note "bin/console fehlt, übersprungen."
elif [ "$DRY_RUN" = "1" ]; then
  note "Trockenlauf: würde 'import-export:delete-expired' ausführen (löscht nur Dateien, deren Aufbewahrung in Shopware abgelaufen ist)."
else
  # shellcheck disable=SC2086
  $PHP bin/console import-export:delete-expired
fi

if [ "$DRY_RUN" = "1" ]; then
  printf '\n%sTrockenlauf: %s Dateien, %s MB. Nichts gelöscht.%s\n' "$C_OK" "$TOTAL_FILES" "$((TOTAL_BYTES / 1024 / 1024))" "$C_END"
else
  mkdir -p "$MARKER_DIR"
  {
    printf 'at=%s\n' "$(date '+%Y-%m-%d %H:%M')"
    printf 'by=%s\n' "$(whoami)"
    printf 'days=%s\nfiles=%s\nmb=%s\n' "$DAYS" "$TOTAL_FILES" "$((TOTAL_BYTES / 1024 / 1024))"
  } > "$MARKER_DIR/last-cleanup"
  printf '\n%sAufgeräumt: %s Dateien, %s MB.%s\n' "$C_OK" "$TOTAL_FILES" "$((TOTAL_BYTES / 1024 / 1024))" "$C_END"
fi
