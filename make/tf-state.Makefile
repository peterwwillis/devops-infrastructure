ROOT := $(shell git rev-parse --show-toplevel)

all: tfsh-asdf tfsh-validate

include $(ROOT)/make/terraformsh.Makefile

import-bucket:
	PLANFILE="$$(terraformsh env sh -c 'echo $$TF_PLANFILE')" ; \
	BUCKET_NAME="$$(terraformsh show -json "$$PLANFILE" | \
        jq -r .planned_values.root_module.child_modules[0].resources[0].values.name)" ; \
    terraformsh import module.bucket.google_storage_bucket.self "$$BUCKET_NAME"
