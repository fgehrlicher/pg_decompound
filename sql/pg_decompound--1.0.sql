\echo Use "CREATE EXTENSION pg_decompound" to load this file. \quit

CREATE FUNCTION pg_decompound_init(internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE FUNCTION pg_decompound_lexize(internal, internal, internal, internal)
RETURNS internal
AS 'MODULE_PATHNAME'
LANGUAGE C STRICT;

CREATE TEXT SEARCH TEMPLATE decompound (
    INIT   = pg_decompound_init,
    LEXIZE = pg_decompound_lexize
);

COMMENT ON TEXT SEARCH TEMPLATE decompound IS
  'splits compound words into their dictionary constituents';
