#!/usr/bin/env bash
# Build pg_decompound, install it into a scratch PostgreSQL, and test it.
#
#   nix develop --command ./test/run.sh      KEEP=1 to keep the scratch dir
#
# An extension must be installed into $SHAREDIR/extension, and the nix store is
# read-only. PostgreSQL derives its paths from its own binary, so relocating the
# server tree gives writable ones.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SCRATCH=${SCRATCH:-$(mktemp -d "${TMPDIR:-/tmp}/pgdc.XXXXXX")}
PGROOT="$SCRATCH/pg"
PGDATA="$SCRATCH/data"
PGPORT=${PGPORT:-54350}
KEEP=${KEEP:-0}

cleanup() {
  [ -f "$PGDATA/postmaster.pid" ] && "$PGROOT/bin/pg_ctl" -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  if [ "$KEEP" = "1" ]; then echo "kept: $SCRATCH"; else rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

say "build"
make --no-print-directory clean >/dev/null 2>&1 || true
make --no-print-directory

say "relocate postgresql into $PGROOT"
PREFIX=$(dirname "$(dirname "$(command -v postgres)")")
mkdir -p "$PGROOT"
cp -RL "$PREFIX"/. "$PGROOT"/
chmod -R u+w "$PGROOT"

say "install the extension"
EXTDIR="$PGROOT/share/postgresql/extension"
TSDIR="$PGROOT/share/postgresql/tsearch_data"
mkdir -p "$EXTDIR" "$TSDIR"
# PGXS emits .dylib on macOS, .so elsewhere. Probe: `ls a b` returns non-zero
# when either is missing and trips set -e.
MODULE=""
for cand in pg_decompound.dylib pg_decompound.so; do
  [ -f "$cand" ] && { MODULE="$cand"; break; }
done
[ -n "$MODULE" ] || { echo "no built module found; did make succeed?" >&2; exit 1; }
install -m 755 "$MODULE"              "$PGROOT/lib/"
install -m 644 pg_decompound.control  "$EXTDIR/"
install -m 644 sql/pg_decompound--*.sql "$EXTDIR/"
echo "  $MODULE -> $PGROOT/lib/"

say "start a scratch cluster on port $PGPORT"
"$PGROOT/bin/initdb" -U postgres -A trust -E UTF8 -D "$PGDATA" >/dev/null
"$PGROOT/bin/pg_ctl" -D "$PGDATA" -o "-p $PGPORT -k $SCRATCH" -l "$SCRATCH/pg.log" start >/dev/null
for _ in $(seq 1 30); do "$PGROOT/bin/pg_isready" -h "$SCRATCH" -p "$PGPORT" >/dev/null 2>&1 && break; sleep 1; done

export PATH="$PGROOT/bin:$PATH"
export PGHOST="$SCRATCH" PGPORT PGUSER=postgres

say "install the word lists"
./tools/build-wordlist.sh german_stem test/german.words > "$TSDIR/german_compounds.dict"
install -m 644 test/olm.dict "$TSDIR/olm.dict"
echo "  german_compounds.dict: $(wc -l < "$TSDIR/german_compounds.dict" | tr -d ' ') entries (generated)"
echo "  olm.dict:              controlled fixture for the option tests"

say "run the regression tests"
make --no-print-directory installcheck
