EXTENSION   = pg_decompound
MODULE_big  = pg_decompound
OBJS        = src/pg_decompound.o
DATA        = sql/pg_decompound--1.0.sql
PGFILEDESC  = "pg_decompound - compound-word splitting for full-text search"

REGRESS         = decompound
REGRESS_OPTS    = --inputdir=test --outputdir=test

PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
