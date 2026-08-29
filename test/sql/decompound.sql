-- pg_decompound behaviour, on German technical vocabulary.

CREATE EXTENSION pg_decompound;

CREATE TEXT SEARCH DICTIONARY german_compounds (
    TEMPLATE = decompound,
    WordList = german_compounds,
    MinPiece = 4,
    MinWord  = 8
);

-- decompound first; non-compounds fall through to the stemmer.
CREATE TEXT SEARCH CONFIGURATION german_dc (COPY = german);
ALTER TEXT SEARCH CONFIGURATION german_dc
    ALTER MAPPING FOR asciiword, word, hword_part, hword_asciipart
    WITH german_compounds, german_stem;

\echo '== 1. compounds split, including every Fugenelement case =='
SELECT w AS compound, ts_lexize('german_compounds', w) AS pieces
FROM unnest(ARRAY[
  'Prüfsummenliste',        -- Fugen-n
  'Sicherheitsstufe',       -- Fugen-s
  'Netzwerkschnittstelle',  -- clean concatenation
  'Administrationshandbuch',
  'Bedienungsanleitung',
  'Konfigurationsdatei',
  'Logmeldungen'
]) w;

\echo '== 2. non-compounds return NULL so the stemmer still gets them =='
SELECT w AS token,
       ts_lexize('german_compounds', w) AS decompound,
       to_tsvector('german_dc', w)::text AS indexed
FROM unnest(ARRAY['Zulassung','Datei','Version','smartcard']) w;

\echo '== 3. the thing stock PostgreSQL cannot do: part matches compound =='
WITH t(compound, query) AS (VALUES
  ('Prüfsummenliste',        'Prüfsumme'),
  ('Prüfsummenliste',        'Liste'),
  ('Administrationshandbuch','Handbuch'),
  ('Netzwerkschnittstelle',  'Schnittstelle'),
  ('Sicherheitsstufe',       'Sicherheit'),
  ('Bedienungsanleitung',    'Anleitung'),
  ('Konfigurationsdatei',    'Datei')
)
SELECT compound, query,
       to_tsvector('german',    compound) @@ plainto_tsquery('german',    query) AS german,
       to_tsvector('german_dc', compound) @@ plainto_tsquery('german_dc', query) AS german_dc
FROM t;

\echo '== 4. the whole compound stays searchable =='
SELECT to_tsvector('german_dc','Prüfsummenliste')
         @@ plainto_tsquery('german_dc','Prüfsummenliste') AS whole_still_matches;

\echo '== 5. positions: parts sit at the compound position, not appended =='
SELECT to_tsvector('german_dc','Die Prüfsummenliste zeigt den Fehler')::text AS tsv;

-- Every lexeme from the second word must carry position 2.
WITH v AS (SELECT to_tsvector('german_dc','Die Prüfsummenliste zeigt den Fehler') AS tsv)
SELECT
  (SELECT count(DISTINCT positions) FROM unnest(tsv)
     WHERE lexeme <> 'zeigt' AND lexeme <> 'fehl') = 1
      AS all_parts_share_one_position,
  (SELECT positions FROM unnest(tsv) WHERE lexeme = 'prufsumm')
     = ARRAY[2]::smallint[]
      AS at_the_compounds_own_position,
  (SELECT max(p) FROM unnest(tsv) t2, unnest(t2.positions) p) <= 5
      AS no_position_past_text_end
FROM v;

\echo '== 6. identifiers must survive untouched =='
SELECT s AS identifier, to_tsvector('german_dc', s)::text AS indexed
FROM unnest(ARRAY['ISO-8601-2019','4.21.7.2']) s;

\echo '== 7. UTF-8 is walked by character, not by byte =='
SELECT length('Prüfsummenliste')       AS chars,
       octet_length('Prüfsummenliste') AS bytes,
       ts_lexize('german_compounds','Prüfsummenliste') AS still_splits;

\echo '== 8. OnlyLongest keeps just the longest match at each offset =='

CREATE TEXT SEARCH DICTIONARY olm_all (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 8
);
CREATE TEXT SEARCH DICTIONARY olm_longest (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 8,
    OnlyLongest = true
);
SELECT ts_lexize('olm_all',     'hausboothafen') AS all_matches,
       ts_lexize('olm_longest', 'hausboothafen') AS longest_only;

\echo '== 9. MinWord and MinPiece boundaries =='

CREATE TEXT SEARCH DICTIONARY olm_minword (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 14
);
CREATE TEXT SEARCH DICTIONARY olm_minpiece (
    TEMPLATE = decompound, WordList = olm, MinPiece = 5, MinWord = 8
);
SELECT ts_lexize('olm_minword',  'hausboothafen') AS below_minword,
       ts_lexize('olm_minpiece', 'hausboothafen') AS pieces_min5;

\echo '== 10. bad configuration is rejected at CREATE time, not at query time =='

DO $$
BEGIN
  BEGIN
    CREATE TEXT SEARCH DICTIONARY bad_nolist (TEMPLATE = decompound);
    RAISE NOTICE 'BUG: missing WordList was accepted';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'rejected: no WordList';
  END;
  BEGIN
    CREATE TEXT SEARCH DICTIONARY bad_param
      (TEMPLATE = decompound, WordList = olm, Nonsense = 3);
    RAISE NOTICE 'BUG: unknown parameter was accepted';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'rejected: unknown parameter';
  END;
  BEGIN
    -- message contains a machine-specific path; assert only the failure
    CREATE TEXT SEARCH DICTIONARY bad_missing
      (TEMPLATE = decompound, WordList = definitely_not_present);
    RAISE NOTICE 'BUG: missing word list file was accepted';
  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'rejected: word list file not found';
  END;
END
$$;

\echo '== 11. inflected variants match (why KeepOriginal defaults off) =='
\echo '   An unstemmed whole-word lexeme is ANDed into the tsquery, so it'
\echo '   would make a plural document invisible to a singular query.'

SELECT d AS document, q AS query,
       to_tsvector('german_dc', d) @@ plainto_tsquery('german_dc', q) AS matches
FROM (VALUES ('Prüfsummenlisten','Prüfsumme'),
             ('Prüfsummenlisten','Prüfsummenliste'),
             ('Prüfsummenliste','Prüfsummenlisten')) t(d,q);

CREATE TEXT SEARCH DICTIONARY olm_keep (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 8,
    KeepOriginal = true
);
SELECT ts_lexize('olm_all',  'hausboothafen') AS default_no_original,
       ts_lexize('olm_keep', 'hausboothafen') AS keep_original;

\echo '== 12. MinCoverage rejects splits that explain too little of the token =='

CREATE TEXT SEARCH DICTIONARY olm_cov (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 8,
    MinCoverage = 70
);
-- hausboothafen is fully covered; xxxxhausyyyy is 4 of 12 characters.
SELECT w, ts_lexize('olm_all', w) AS no_threshold, ts_lexize('olm_cov', w) AS cov70
FROM unnest(ARRAY['hausboothafen','xxxxhausyyyy']) w;

\echo '== 13. the cover is optimal, not greedy =='
\echo '   hausbootsteg: greedy takes the longest match hausboots (9) and'
\echo '   strands teg, reaching 9 of 12 characters. The best cover is'
\echo '   hausboot + steg, all 12.'

SELECT ts_lexize('olm_cov', 'hausbootsteg') AS optimal_cover;

\echo '== 14. MaxWord bounds the quadratic matching cost =='
\echo '   Matching is O(n^2) in token length. Nothing longer than a real'
\echo '   compound is worth scanning; the longest German word in ordinary'
\echo '   use is 63 characters.'

CREATE TEXT SEARCH DICTIONARY olm_max (
    TEMPLATE = decompound, WordList = olm, MinPiece = 4, MinWord = 8,
    MaxWord = 20
);
SELECT length(w) AS chars,
       ts_lexize('olm_all', w) IS NOT NULL AS default_splits,
       ts_lexize('olm_max', w) IS NOT NULL AS maxword20_splits
FROM unnest(ARRAY['hausboothafen', repeat('hausboothafen', 4)]) w;
