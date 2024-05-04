ROOT := $(shell git rev-parse --show-toplevel)

all: tfsh-asdf \
     terraform-docs-asdf \
     tfsh-fmt \
     tfsh-validate-nobackend \
     terraform-docs-markdown-output-README

include $(ROOT)/make/terraformsh.Makefile
include $(ROOT)/make/terraform-docs.Makefile
