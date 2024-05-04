ROOT ?= $(shell git rev-parse --show-toplevel)

include $(ROOT)/make/asdf.Makefile
TERRAFORMSH_HELP_TARGETS := tfsh-help-general tfsh-help-asdf tfsh-help-validate tfsh-help-validate-nobackend tfsh-help-plan tfsh-help-apply tfsh-help-plan-destroy tfsh-help-destroy tfsh-help-fmt tfsh-help-output tfsh-help-providers-lock tfsh-help-shell tfsh-help-clean

tfsh-help: $(TERRAFORMSH_HELP_TARGETS)
	@echo "Required environment variables:"
	@echo ""
	@echo "Optional environment variables:"
	@echo "  TF_OPTS                Extra arguments for 'tfsh-plan', 'tfsh-apply', "
	@echo "                         tfsh-plan-destroy' and 'tfsh-destroy."
# Alias to match the help function used by helm-chart.Makefile
help-targets: tfsh-help


tfsh-help-asdf:
	@echo "   tfsh-asdf                 Install all ASDF plugins"
tfsh-asdf: asdf-add-install-plugin
# We install all plugins because asdf install errors out if some plugins aren't installed

tfsh-help-validate:
	@echo "   tfsh-validate             Run 'terraformsh validate'"
tfsh-validate: tfsh-asdf
	terraformsh validate

tfsh-help-validate-nobackend:
	@echo "   tfsh-validate-nobackend   Run 'terraformsh validate' disabling the backend"
# Override the backend when validating in this module directory, so we can validate even if there's
# no valid backend configured.
tfsh-validate-nobackend: tfsh-asdf
	terraformsh -E "INIT_ARGS=-backend=false" validate

tfsh-help-plan:
	@echo "   tfsh-plan                 Run 'terraformsh plan'"
tfsh-plan: tfsh-require-backend-config tfsh-asdf
	terraformsh plan $(TF_OPTS)

tfsh-help-apply:
	@echo "   tfsh-apply                Run 'terraformsh apply'"
tfsh-apply: tfsh-require-backend-config tfsh-asdf
	terraformsh apply $(TF_OPTS)

tfsh-help-plan-destroy:
	@echo "   tfsh-plan-destroy         Run 'terraformsh plan_destroy'"
tfsh-plan-destroy: tfsh-require-backend-config tfsh-asdf
	terraformsh plan_destroy $(TF_OPTS)

tfsh-help-destroy:
	@echo "   tfsh-destroy              Run 'terraformsh destroy'"
tfsh-destroy: tfsh-require-backend-config tfsh-asdf
	terraformsh destroy $(TF_OPTS)

tfsh-help-import:
	@echo "   tfsh-import              Run 'terraformsh import'"
tfsh-import: tfsh-require-backend-config tfsh-asdf
	terraformsh import $(TF_OPTS)

tfsh-help-fmt:
	@echo "   tfsh-fmt                  Run 'terraformsh fmt'"
tfsh-fmt: tfsh-asdf
	terraformsh fmt

tfsh-help-output:
	@echo "   tfsh-output               Run 'terraformsh output'"
tfsh-output: tfsh-asdf
	terraformsh output

tfsh-help-providers-lock:
	@echo "   tfsh-providers-lock       Run 'terraformsh providers lock'"
tfsh-providers-lock: tfsh-asdf
	terraformsh providers lock

tfsh-help-shell:
	@echo "   tfsh-shell                Run 'terraformsh shell'"
tfsh-shell: tfsh-asdf
	terraformsh shell

tfsh-help-clean:
	@echo "   tfsh-clean                Run 'terraformsh clean'"
tfsh-clean: tfsh-asdf
	terraformsh clean

tfsh-help-general:
	@echo "Make targets for Terraformsh:"

tfsh-require-backend-config:
	@if [ ! -e backend.sh.tfvars ] && [ ! "$${SKIP_REQUIRED_BACKEND_CONFIG:-0}" = "1" ] ; then \
        echo "ERROR: No backend.sh.tfvars found in this directory ($$(pwd))!" ; \
        echo "ERROR: Please make sure your backend is configured properly!" ; \
        exit 1 ; \
    fi
