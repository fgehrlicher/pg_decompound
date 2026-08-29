#!/usr/bin/env bash
# Turn a plain word list into the two-column format pg_decompound loads.
#
#   build-wordlist.sh german_stem words.txt > german_compounds.dict
#
# The second column is the pre-stemmed lexeme. A dictionary that answers stops
# the configuration chain, so the stemmer never sees these pieces.
#
# Extra arguments go to psql, e.g. -h /tmp -p 54350 -U postgres.
set -euo pipefail

CONFIG=${1:?usage: build-wordlist.sh <ts_dictionary> <wordfile> [psql args...]}
WORDS=${2:?usage: build-wordlist.sh <ts_dictionary> <wordfile> [psql args...]}
shift 2

# \copy only works in a script stream, never in psql -c.
{
  printf 'CREATE TEMP TABLE w(word text);\n'
  printf '\\copy w FROM STDIN\n'
  grep -v '^[[:space:]]*#' "$WORDS" | grep -v '^[[:space:]]*$'
  printf '\\.\n'
  printf "SELECT w.word || E'\\t' ||\n"
  printf "       coalesce((ts_lexize(:'cfg'::regdictionary, w.word))[1], w.word)\n"
  printf 'FROM w ORDER BY w.word;\n'
} | psql -qtAX -v cfg="$CONFIG" "$@" -f -
