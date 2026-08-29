/*
 * SPDX-License-Identifier: MIT
 *
 * pg_decompound - compound-word splitting for full-text search.
 *
 * Text search dictionary template. Emits every dictionary word found inside a
 * token.
 *
 * Pieces need not cover the whole token. This is what makes German work:
 * "Prüfsummenliste" yields "prüfsumme" and "liste", ignoring the linking "n"
 * that defeats PostgreSQL's built-in ispell compound support.
 *
 * The matching follows Lucene's DictionaryCompoundWordTokenFilter, from its
 * documented behaviour rather than its source. MinCoverage and the DP cover
 * are additions; Lucene emits every match unconditionally.
 */
#include "postgres.h"

#include "commands/defrem.h"
#include "mb/pg_wchar.h"
#include "tsearch/ts_locale.h"
#include "tsearch/ts_public.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC;

typedef struct
{
	char	   *surface;		/* lowercased form as it appears in a compound */
	char	   *lexeme;			/* what to emit; equals surface when unmapped */
} DictEntry;

typedef struct
{
	DictEntry  *entries;
	int			nentries;
	int			minpiece;		/* shortest piece worth emitting, in chars */
	int			minword;		/* shortest token worth splitting, in chars */
	int			maxword;		/* longest token worth splitting; matching is
								 * quadratic in token length, and nothing above
								 * this is a real compound anyway */
	bool		onlylongest;	/* at each offset, keep only the longest hit */
	bool		keeporiginal;	/* also emit unmapped tokens verbatim */
	int			mincoverage;	/* 0 = every match; else % of token that the
								 * non-overlapping cover must span */
} DictDecompound;

PG_FUNCTION_INFO_V1(pg_decompound_init);
PG_FUNCTION_INFO_V1(pg_decompound_lexize);

static int
entry_cmp(const void *a, const void *b)
{
	return strcmp(((const DictEntry *) a)->surface,
				  ((const DictEntry *) b)->surface);
}

/*
 * Loads "<name>.dict" from $SHAREDIR/tsearch_data.
 *
 * Format: one entry per line, "surface" or "surface<TAB>lexeme".
 *
 * The lexeme must be pre-stemmed. A dictionary that answers stops the
 * configuration chain, so the stemmer never sees these pieces. See
 * tools/build-wordlist.sh.
 */
static void
load_wordlist(DictDecompound *d, const char *name)
{
	char	   *filename = get_tsearch_config_filename(name, "dict");
	tsearch_readline_state trst;
	char	   *line;
	int			capacity = 4096;

	if (!tsearch_readline_begin(&trst, filename))
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("could not open decompound word list \"%s\"", filename)));

	d->entries = (DictEntry *) palloc(capacity * sizeof(DictEntry));
	d->nentries = 0;

	while ((line = tsearch_readline(&trst)) != NULL)
	{
		char	   *tab;
		char	   *surface;
		char	   *lexeme;
		char	   *p;

		/* strip trailing whitespace, then skip blanks and comments */
		p = line + strlen(line);
		while (p > line && (p[-1] == '\n' || p[-1] == '\r' ||
							p[-1] == ' ' || p[-1] == '\t'))
			*--p = '\0';
		if (*line == '\0' || *line == '#')
		{
			pfree(line);
			continue;
		}

		tab = strchr(line, '\t');
		if (tab != NULL)
		{
			*tab = '\0';
			lexeme = lowerstr(tab + 1);
		}
		else
			lexeme = NULL;

		surface = lowerstr(line);
		if (*surface == '\0')
		{
			pfree(surface);
			if (lexeme)
				pfree(lexeme);
			pfree(line);
			continue;
		}
		if (lexeme == NULL || *lexeme == '\0')
		{
			if (lexeme)
				pfree(lexeme);
			lexeme = pstrdup(surface);
		}

		if (d->nentries >= capacity)
		{
			capacity *= 2;
			d->entries = (DictEntry *)
				repalloc(d->entries, capacity * sizeof(DictEntry));
		}
		d->entries[d->nentries].surface = surface;
		d->entries[d->nentries].lexeme = lexeme;
		d->nentries++;

		pfree(line);
	}

	tsearch_readline_end(&trst);

	if (d->nentries == 0)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIG_FILE_ERROR),
				 errmsg("decompound word list \"%s\" is empty", filename)));

	qsort(d->entries, d->nentries, sizeof(DictEntry), entry_cmp);
}

/* Dictionary lookup for the substring token[bound[i] .. bound[j]). */
static DictEntry *
lookup_piece(DictDecompound *d, const char *token, const int *bound, int i, int j)
{
	DictEntry	key;
	DictEntry  *hit;
	int			blen = bound[j] - bound[i];
	char	   *piece = palloc(blen + 1);

	memcpy(piece, token + bound[i], blen);
	piece[blen] = '\0';
	key.surface = piece;
	key.lexeme = NULL;
	hit = (DictEntry *) bsearch(&key, d->entries, d->nentries,
								sizeof(DictEntry), entry_cmp);
	pfree(piece);
	return hit;
}

Datum
pg_decompound_init(PG_FUNCTION_ARGS)
{
	List	   *dictoptions = (List *) PG_GETARG_POINTER(0);
	DictDecompound *d;
	ListCell   *l;
	char	   *wordlist = NULL;

	d = (DictDecompound *) palloc0(sizeof(DictDecompound));
	d->minpiece = 4;
	d->minword = 8;
	d->maxword = 100;
	d->onlylongest = false;
	d->keeporiginal = false;
	d->mincoverage = 0;

	foreach(l, dictoptions)
	{
		DefElem    *defel = (DefElem *) lfirst(l);

		if (pg_strcasecmp(defel->defname, "WordList") == 0)
		{
			if (wordlist != NULL)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("multiple WordList parameters")));
			wordlist = pstrdup(defGetString(defel));
		}
		else if (pg_strcasecmp(defel->defname, "MinPiece") == 0)
			d->minpiece = atoi(defGetString(defel));
		else if (pg_strcasecmp(defel->defname, "MinWord") == 0)
			d->minword = atoi(defGetString(defel));
		else if (pg_strcasecmp(defel->defname, "MaxWord") == 0)
			d->maxword = atoi(defGetString(defel));
		else if (pg_strcasecmp(defel->defname, "OnlyLongest") == 0)
			d->onlylongest = defGetBoolean(defel);
		else if (pg_strcasecmp(defel->defname, "KeepOriginal") == 0)
			d->keeporiginal = defGetBoolean(defel);
		else if (pg_strcasecmp(defel->defname, "MinCoverage") == 0)
			d->mincoverage = atoi(defGetString(defel));
		else
			ereport(ERROR,
					(errcode(ERRCODE_SYNTAX_ERROR),
					 errmsg("unrecognized decompound parameter: \"%s\"",
							defel->defname)));
	}

	if (wordlist == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("decompound dictionary requires a WordList parameter")));
	if (d->minpiece < 1)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("MinPiece must be at least 1")));
	if (d->mincoverage < 0 || d->mincoverage > 100)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("MinCoverage must be between 0 and 100")));

	load_wordlist(d, wordlist);

	PG_RETURN_POINTER(d);
}

/*
 * Appends a lexeme unless already present; returns the new count.
 * No TSL_ADDPOS, so every lexeme shares the token's position.
 */
static int
append_lexeme(TSLexeme **res, int nres, int *capacity, const char *lexeme)
{
	int			k;

	for (k = 0; k < nres; k++)
		if (strcmp((*res)[k].lexeme, lexeme) == 0)
			return nres;

	if (nres + 2 > *capacity)
	{
		*capacity = *capacity * 2 + 2;
		*res = (TSLexeme *) repalloc(*res, *capacity * sizeof(TSLexeme));
		memset(*res + nres, 0, (*capacity - nres) * sizeof(TSLexeme));
	}
	(*res)[nres].lexeme = pstrdup(lexeme);
	(*res)[nres].flags = 0;
	(*res)[nres].nvariant = 0;
	return nres + 1;
}

Datum
pg_decompound_lexize(PG_FUNCTION_ARGS)
{
	DictDecompound *d = (DictDecompound *) PG_GETARG_POINTER(0);
	char	   *in = (char *) PG_GETARG_POINTER(1);
	int32		inlen = PG_GETARG_INT32(2);
	char	   *token;
	int			tlen;
	int		   *bound;			/* byte offset of each character boundary */
	int			nchars = 0;
	TSLexeme   *res;
	int			nres = 0;
	int			capacity = 8;
	int			i;

	if (inlen <= 0)
		PG_RETURN_POINTER(NULL);

	token = lowerstr_with_len(in, inlen);
	tlen = strlen(token);

	/* Walk character boundaries: slicing mid-character yields invalid UTF-8. */
	bound = (int *) palloc((tlen + 1) * sizeof(int));
	for (i = 0; i < tlen;)
	{
		bound[nchars++] = i;
		i += pg_mblen(token + i);
	}
	bound[nchars] = tlen;

	if (nchars < d->minword || nchars < 2 * d->minpiece ||
		(d->maxword > 0 && nchars > d->maxword))
	{
		pfree(bound);
		pfree(token);
		PG_RETURN_POINTER(NULL);
	}

	res = (TSLexeme *) palloc0(capacity * sizeof(TSLexeme));

	if (d->mincoverage > 0)
	{
		/*
		 * Best non-overlapping cover, discarded unless it spans enough of the
		 * token.
		 *
		 * Emitting every substring match is too noisy against a large word
		 * list: "administrationshandbuch" also yields "mini" and "ration"
		 * from inside "administration", and English "checksum" yields German
		 * "heck". MinPiece and OnlyLongest do not remove those, because the
		 * spurious pieces nest inside real ones or begin at another offset.
		 *
		 * The cover is chosen by dynamic programming rather than greedily.
		 * Taking the longest match at each position is measurably worse:
		 * "netzwerkschnittstelle" offers "werks" at offset 4, and preferring
		 * it over "werk" consumes the s and blocks "schnitt" at offset 8,
		 * covering 15 of 21 characters where the best cover reaches 21.
		 */
		int		   *cover = (int *) palloc((nchars + 1) * sizeof(int));
		int		   *choice = (int *) palloc((nchars + 1) * sizeof(int));
		int			pos;

		cover[nchars] = 0;
		choice[nchars] = -1;

		for (pos = nchars - 1; pos >= 0; pos--)
		{
			int			j;

			cover[pos] = cover[pos + 1];	/* leave this character uncovered */
			choice[pos] = -1;

			for (j = nchars; j - pos >= d->minpiece; j--)
			{
				if (j - pos == nchars)
					continue;
				if (lookup_piece(d, token, bound, pos, j) == NULL)
					continue;
				if ((j - pos) + cover[j] > cover[pos])
				{
					cover[pos] = (j - pos) + cover[j];
					choice[pos] = j;
				}
			}
		}

		if (cover[0] * 100 >= d->mincoverage * nchars)
		{
			pos = 0;
			while (pos < nchars)
			{
				DictEntry  *hit;

				if (choice[pos] < 0)
				{
					pos++;
					continue;
				}
				hit = lookup_piece(d, token, bound, pos, choice[pos]);
				nres = append_lexeme(&res, nres, &capacity, hit->lexeme);
				pos = choice[pos];
			}
		}

		pfree(cover);
		pfree(choice);
	}
	else
	{
		/* every dictionary word at every offset: Lucene's behaviour */
		for (i = 0; i < nchars; i++)
		{
			int			j;

			/* count down so the first hit at this offset is the longest */
			for (j = nchars; j - i >= d->minpiece; j--)
			{
				DictEntry  *hit;

				if (j - i == nchars)
					continue;

				hit = lookup_piece(d, token, bound, i, j);
				if (hit == NULL)
					continue;

				nres = append_lexeme(&res, nres, &capacity, hit->lexeme);
				if (d->onlylongest)
					break;
			}
		}
	}

	/*
	 * NULL means "unknown word", passing the token to the next dictionary. An
	 * empty array would mean "stop word" and drop every non-compound.
	 */
	if (nres == 0)
	{
		pfree(bound);
		pfree(res);
		pfree(token);
		PG_RETURN_POINTER(NULL);
	}

	/*
	 * Emit the whole token when the dictionary maps it: that lexeme is
	 * pre-stemmed and so agrees with the stemmer elsewhere.
	 *
	 * Otherwise emit it only under KeepOriginal. The raw form is unstemmed,
	 * and every lexeme of a token is ANDed into the tsquery, so an unstemmed
	 * whole-word lexeme makes inflected variants miss: a query for
	 * "Prüfsummenliste" would not find a document saying "Prüfsummenlisten".
	 */
	{
		DictEntry  *whole = lookup_piece(d, token, bound, 0, nchars);

		if (whole != NULL)
			nres = append_lexeme(&res, nres, &capacity, whole->lexeme);
		else if (d->keeporiginal)
			nres = append_lexeme(&res, nres, &capacity, token);
	}

	pfree(bound);
	pfree(token);

	res[nres].lexeme = NULL;	/* array terminator */

	PG_RETURN_POINTER(res);
}
