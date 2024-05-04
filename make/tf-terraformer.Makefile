ROOT := $(shell git rev-parse --show-toplevel)

all: tfr-help

include $(ROOT)/make/terraformer.Makefile
-include Makefile.inc
