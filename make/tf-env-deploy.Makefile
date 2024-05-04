ROOT := $(shell git rev-parse --show-toplevel)

all: tfsh-help

include $(ROOT)/make/terraformsh.Makefile
