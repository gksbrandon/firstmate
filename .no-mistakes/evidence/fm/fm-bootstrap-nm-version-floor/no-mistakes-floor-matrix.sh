#!/usr/bin/env bash
# Drives bin/fm-bootstrap.sh with a stub `no-mistakes` first on PATH.
# Everything else on PATH is the real installed toolchain on this machine.
set -u
ROOT=$1
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-matrix.XXXXXX")
mkdir -p "$SCRATCH/home/config" "$SCRATCH/fakebin"
printf '%s\n' manual > "$SCRATCH/home/config/backlog-backend"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SCRATCH/fakebin/tmux"
cat > "$SCRATCH/fakebin/no-mistakes" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' "$FAKE_NM_VERSION"
  [ -z "${FAKE_NM_EXTRA:-}" ] || printf '%s\n' "$FAKE_NM_EXTRA"
  exit 0
fi
exit 0
STUB
chmod +x "$SCRATCH/fakebin/tmux" "$SCRATCH/fakebin/no-mistakes"

emit() {
  local version=$1 extra=$2 out
  printf '$ no-mistakes --version\n%s\n' "$version"
  [ -z "$extra" ] || printf '%s\n' "$extra"
  out=$(PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$SCRATCH/home" FM_ROOT_OVERRIDE="$SCRATCH/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip \
    FAKE_NM_VERSION="$version" FAKE_NM_EXTRA="$extra" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  printf '$ fm-bootstrap.sh\n%s\n' "${out:-<silent>}"
  out=$(PATH="$SCRATCH/fakebin:$PATH" FM_HOME="$SCRATCH/home" FM_ROOT_OVERRIDE="$SCRATCH/home" \
    FM_BOOTSTRAP_DETECT_ONLY=1 FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_VERBOSE_FACTS=1 \
    FAKE_NM_VERSION="$version" FAKE_NM_EXTRA="$extra" "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null \
    | grep -E 'no-mistakes')
  printf '$ FM_BOOTSTRAP_VERBOSE_FACTS=1 fm-bootstrap.sh   # no-mistakes lines only\n%s\n\n' "${out:-<none>}"
}

while IFS='^' read -r title version extra; do
  [ -n "$title" ] || continue
  printf -- '--- %s\n' "$title"
  emit "$version" "$extra"
done <<'ROWS'
at the floor^no-mistakes version v1.31.2 (fake) 2026-06-27T00:02:18Z^
at the floor, no v prefix^no-mistakes version 1.31.2^
newer than the floor^no-mistakes version v2.0.0 (fake)^
below the floor^no-mistakes version v1.31.1 (fake)^
below the floor, update nag on a following line^no-mistakes version 1.30.0^A new version of no-mistakes is available: 1.30.0 -> v1.60.2
below the floor, update nag on the SAME line^no-mistakes version 1.30.0 (update available 1.60.2)^
at the floor, older release also on the line^no-mistakes version 1.31.2 (previous 1.30.0)^
dev build (captain's fork stamp)^no-mistakes version v0-unstable-9f4698d (9f4698d) unknown^
dev build with an update nag after it^no-mistakes version v0-unstable-9f4698d (9f4698d) unknown^A new version of no-mistakes is available: v0-unstable-9f4698d -> v1.60.2
unlabelled development build^no-mistakes development build^
ROWS
rm -rf "$SCRATCH"
