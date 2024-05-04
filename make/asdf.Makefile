ROOT ?= $(shell git rev-parse --show-toplevel)

asdf-add-install-plugin:
	grep '^# asdf plugin add ' $(ROOT)/.tool-versions \
    | sed -E 's/^# //' \
    | tr '\n' '\0' \
    | xargs -0 -I{} sh -c {}
	asdf install

asdf:
	asdf install

