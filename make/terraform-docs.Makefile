ROOT ?= $(shell git rev-parse --show-toplevel)

include $(ROOT)/make/asdf.Makefile

terraform-docs-asdf: asdf-add-install-plugin
	# We install all plugins because asdf install errors out if some plugins aren't installed

terraform-docs-markdown-output-README:
	terraform-docs markdown table . --output-file README.md --output-mode inject
