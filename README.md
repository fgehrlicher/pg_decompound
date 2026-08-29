# pg_decompound

A PostgreSQL text search dictionary template that splits compound words into
their constituents, at index and query time.

```
Konfigurationsdatei    ->  konfiguration, datei
Zugriffskontrolle      ->  zugriff, kontroll
Netzwerkkonfiguration  ->  netz, werk, konfiguration
```

Lexemes are the pre-stemmed forms held in the word list, so they are not
always spelled like the words they came from.

The word list determines the language. Developed against German; the same
approach covers Dutch, the Scandinavian languages, Finnish and Hungarian.

## Install

```sh
make && make install          # needs the PostgreSQL server headers
```

With nix: `nix develop`

## Configure

```sql
CREATE EXTENSION pg_decompound;

CREATE TEXT SEARCH DICTIONARY german_compounds (
    TEMPLATE = decompound,
    WordList = german_compounds,   -- $SHAREDIR/tsearch_data/german_compounds.dict
    MinPiece = 4,
    MinWord  = 8,
    MinCoverage = 70
);

CREATE TEXT SEARCH CONFIGURATION german_dc (COPY = german);
ALTER TEXT SEARCH CONFIGURATION german_dc
    ALTER MAPPING FOR asciiword, word, hword_part, hword_asciipart
    WITH german_compounds, german_stem;
```

List `decompound` before the stemmer. It returns NULL for anything it cannot
split, so other tokens fall through.

| Parameter | Default | Description |
|---|---|---|
| `WordList` | required | Basename of `<name>.dict` in `$SHAREDIR/tsearch_data` |
| `MinPiece` | 4 | Shortest piece to emit, in characters |
| `MinWord` | 8 | Shortest token to attempt |
| `MaxWord` | 100 | Longest token to attempt, 0 for no limit |
| `MinCoverage` | 0 | Percent of the token the pieces must span. 0 emits every match |
| `OnlyLongest` | false | Keep only the longest match at each offset |
| `KeepOriginal` | false | Also index the compound itself, unstemmed |

Matching is quadratic in token length, so `MaxWord` skips tokens too long to
be real compounds. The default of 100 clears the longest German word in
ordinary use (63 characters) and keeps a 2000-character blob from costing
tens of milliseconds.

With `MinCoverage` above 0 the pieces are chosen as the best non-overlapping
cover of the token, and the split is discarded if it spans too little. With 0
every dictionary word found at any offset is emitted, which is Lucene's
`DictionaryCompoundWordTokenFilter` behaviour.

## Word list

One entry per line, `surface` or `surface<TAB>lexeme`.

```
prüfsumme	prufsumm
liste	list
```

The lexeme must be pre-stemmed. A dictionary that answers stops the
configuration chain, so the stemmer never sees these pieces. Generate the
second column with:

```sh
./tools/build-wordlist.sh german_stem words.txt > german_compounds.dict
```

Supply constituents, not compounds. `Prüfsummenliste` splits because
`prüfsumme` and `liste` are in the list; the compound itself never needs to be.

### German

[uschindler/german-decompounder](https://github.com/uschindler/german-decompounder)
publishes a 14,526-word list curated for this, one lowercase word per line:

```sh
curl -LO https://raw.githubusercontent.com/uschindler/german-decompounder/master/dictionary-de.txt
./tools/build-wordlist.sh german_stem dictionary-de.txt > german_compounds.dict
```

**Set `MinCoverage` with a list this size.** Emitting every substring match is
too noisy: `Administrationshandbuch` also yields `mini` and `ration` from
inside `administration`, and the English `checksum` yields the German `heck`.
`MinPiece` does not help, because the spurious pieces are not short.
`MinCoverage = 70` removed all of it in testing while keeping every real
constituent.

## Test

```sh
nix develop --command ./test/run.sh
```

Builds, relocates PostgreSQL to a scratch directory, starts a cluster and runs
`make installcheck`. `KEEP=1` keeps the scratch directory.

Tests are pg_regress: `test/sql/decompound.sql` against
`test/expected/decompound.out`. To update after an intentional change, review
`test/results/decompound.out` and copy it over the expected file.

## Limitations

- Compounds are found through their constituents, not as a lexeme of their
  own. `KeepOriginal` adds one, but it is unstemmed, and PostgreSQL ANDs every
  lexeme of a token into the query: a document saying `Prüfsummenlisten` would
  then be invisible to a query for `Prüfsummenliste`. Enable it only if you
  never need to match across inflections.
- A query term and the document must decompose the same way. Every lexeme of
  a token is ANDed into the query, so a query whose split contains a piece the
  document's split does not will miss. `Benutzer` yields `nutz` and `benutz`
  while `Benutzerhandbuch` yields `benutz`, `hand` and `buch`, so that query
  fails even though both contain `benutz`.

## Licence

MIT, see [LICENSE](LICENSE).

That covers the code only. **Word lists are separate and are not MIT.** German
dictionaries derived from igerman98 are described upstream as GPL-2/3, which is
why none ships here, and `build-wordlist.sh` output is a derivative of whatever
you feed it. Check the terms of any list you redistribute.
