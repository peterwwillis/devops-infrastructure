-include Makefile.inc

##################################################################
# 
# This Makefile is designed to deploy Helm charts.
# You can use this Makefile in a couple different ways:
# 
# 1. A chart's Makefile.
#    This allows you to run Helm commands on a chart from its
#    directory, such as 'template', 'upgrade', etc. You can also
#    use the 'make deps' command to build all the dependencies
#    of the chart.
#    
#    Place this Makefile in a Helm chart directory along with a
#    'Makefile.inc' file which defines the following variables:
#        HELM_RELASE := name-of-the-release
#        HELM_CHART := .
# 
# 2. A subchart's Makefile. 
#    This allows you to perform Helm commands from the subchart
#    directory. This Makefile is also called in a subchart
#    directory by the 'make deps' target of a parent chart.
#    
#    In the subchart directory, place a new file called 'Makefile'
#    with only these contents:
#        include ../../Makefile
#    Then create the Makefile.inc as described above.
# 
# 3. A deployment Makefile.
#    This allows you to perform deployments of a Helm chart.
#    You can also deploy a remotely hosted chart.
#    
#    Place this Makefile in an arbitrary directory.
#    In the same directory, place this in Makefile.inc:
#        # NOTE: You cannot use a 'root' symlink with Helm
#        HELM_RELEASE := name-of-the-release
#        HELM_CHART := ../../../../../../../path/to/chart
#        DEFAULT_TARGETS := clean deps upgrade
#        K8S_NS=k8s-namespace-here
#
#    To deploy a remotely hosted chart, use this as the
#    Makefile.inc:
#        HELM_RELEASE ?= cert-manager
#        HELM_REPO := jetstack
#        HELM_REPO_URL := https://charts.jetstack.io
#        HELM_CHART := jetstack/cert-manager
#        HELM_CHART_VERSION ?= v1.10.1
#        HELM_INSTALL_OPTS_EXTRA += \
#            --set installCRDs=true \
#            --set global.leaderElection.namespace=$(K8S_NS)
#        K8S_NS=k8s-namespace-here
# 
# You can pass any variables in this Makefile through the
# 'Makefile.inc' file described above, such as 'HELM_VALUES=..'.
# 
# You cannot run this Makefile from a directory with a symlink to
# a parent directory. Helm has a directory traversal bug which will
# make it die due to a failed recursion.
# 
##################################################################

# Try to use values.yaml from the directory 'make' was called from
HELM_VALUES ?= $(CURDIR)/values.yaml

# Default helm timeout
HELM_TIMEOUT ?= 10m0s

DEFAULT_TARGETS ?= help-targets

ROOT ?= $(shell git rev-parse --show-toplevel)

all: $(DEFAULT_TARGETS)

help-targets:
	@echo "Targets:"
	@echo "  deps                   Update and build Helm chart dependencies"
	@echo "  template               Run 'helm template'"
	@echo "  dry-install            Run 'helm install --dry-run=server'"
	@echo "  dry-upgrade            Run 'helm upgrade --dry-run=server'"
	@echo "  dry-diff-upgrade       Run 'helm diff upgrade --dry-run=server'"
	@echo "  dry-custom-deploy      Generate custom values.yaml for a custom deployment"
	@echo "  install                Run 'helm install'"
	@echo "  upgrade                Run 'helm upgrade'"
	@echo "  diff-upgrade           Run 'helm diff upgrade'"
	@echo "  custom-deploy          Generate and apply custom values.yaml for custom deployment"
	@echo "  uninstall              Run 'helm uninstall'"
	@echo "  lint                   Run 'helm lint'"
	@echo "  clean                  Remove Chart.lock, HELM_CHART/**.tgz"
	@echo "  generate-subcharts     Generates subcharts using an old k8s manifest"
	@echo ""
	@echo "Required environment variables:"
	@echo "  K8S_NS                 The Kubernetes namespace to use for the Helm deploy"
	@echo "  HELM_CHART             The name or path of the helm chart to deploy"
	@echo "  HELM_RELEASE           The name of the helm release to deploy"
	@echo ""
	@echo "Optional environment variables:"
	@echo "  HELM_REPO              If passed with HELM_REPO_URL, this is the name of a"
	@echo "                         remote helm repository to add and install charts from."
	@echo "  HELM_REPO_URL          If passed with HELM_REPO, this is the name of a remote"
	@echo "                         helm repository URL to add and install charts from."
	@echo "  HELM_CHART_VERSION     If set, passes '--version=HELM_CHART_VERSION' to helm."
	@echo "  HELM_VALUES            A file to pass to the helm '-f' option".
	@echo "  HELM_INSTALL_OPTS_EXTRA        Extra arguments for 'helm install' and"
	@echo "                                 'helm upgrade'."
	@echo "  HELM_TEMPLATE_OPTS_EXTRA       Extra arguments for 'helm template'."
	@echo "  HELM_EXTRA_VALUES              Extra values.yaml files to pass to helm."


req-params:
	@if [ -z "$(K8S_NS)" ] ; then \
        echo "Error: Please pass K8S_NS to continue" ; exit 1 ; \
    fi
	@if [ -z "$(HELM_CHART)" ] ; then \
        echo "Error: Please pass HELM_CHART env var to helm-chart.Makefile" ; exit 1 ; \
    fi
	@if [ -z "$(HELM_RELEASE)" ] ; then \
        echo "Error: Please pass HELM_RELEASE env var to helm-chart.Makefile" ; exit 1 ; \
    fi
	@if [ -z "$(ROOT)" ] ; then \
        echo "Error: Please pass ROOT env var to helm-chart.Makefile" ; exit 1 ; \
    fi

check-subchart-values:
	$(ROOT)/helm/bin/manage-values.sh check_values "$(HELM_CHART)"

##########################################
# update dependencies

# NOTE: If you don't generate the dependencies in each subchart,
# 'helm template' will not render anything in the parent. :-(
# Pass PARALLEL_DEPS=10 to up number of deps to process at once to 10
# NOTE: If you don't run 'make clean', and a subchart is removed from Git,
# the files in $(HELM_CHART)/.gitignore remain in a local working copy,
# and that breaks the subsequent Helm commands which think the chart should exist but is
# missing a Chart.yaml file. Removing the files is necessary to get Helm commands to work.
deps: check-subchart-values
	HELM_CHART="$(HELM_CHART)" PARALLEL_DEPS="$(PARALLEL_DEPS)" $(ROOT)/helm/bin/makedeps.sh

##########################################
# 'helm template'
HELM_TEMPLATE_OPTS = \
        --namespace "$(K8S_NS)" \
        --create-namespace \
        --debug \
        --dry-run=server \
        $(HELM_TEMPLATE_OPTS_EXTRA)
HELM_TEMPLATE_OPTS += $(foreach file,$(yamlfileargs),-f "$(file)")

template: template-base clean-tmp
template-base: req-params repo deps
	helm template "$(HELM_RELEASE)" "$(HELM_CHART)" $(HELM_TEMPLATE_OPTS)

##########################################
# 'helm repo' - add a repository if one was specified
repo: req-params
	@if [ -n "$(HELM_REPO)" ] && [ -n "$(HELM_REPO_URL)" ] ; then \
        repo_exists=$$( helm repo list | tail -n +2 | grep -E '^$(HELM_REPO)[[:space:]]' ) ; \
        if [ -z "$$repo_exists" ] ; then \
        	helm repo add "$(HELM_REPO)" "$(HELM_REPO_URL)" ; \
        fi ; \
        helm repo update ; \
    fi

##########################################
# 'helm install'

# This is used by both 'helm install' and 'helm upgrade'.
HELM_INSTALL_OPTS = \
        --atomic \
        --wait-for-jobs \
        --timeout $(HELM_TIMEOUT) \
        --namespace "$(K8S_NS)" \
        --create-namespace \
        --debug \
        --dependency-update \
        $(HELM_INSTALL_OPTS_EXTRA)
ifneq ($(HELM_CHART_VERSION),)
HELM_INSTALL_OPTS += --version="$(HELM_CHART_VERSION)"
endif
HELM_INSTALL_OPTS += $(foreach file,$(yamlfileargs),-f "$(file)")

HELM_UPGRADE_OPTS = $(HELM_INSTALL_OPTS) \
        --cleanup-on-fail \
        --history-max 0

dry-install: dry-install-base clean-tmp
dry-install-base: req-params repo deps
	set -eu; helm install "$(HELM_RELEASE)" "$(HELM_CHART)" \
        $(HELM_INSTALL_OPTS) --dry-run=server
install: install-base clean-tmp
install-base: req-params repo deps
	set -eu; helm install "$(HELM_RELEASE)" "$(HELM_CHART)" $(HELM_INSTALL_OPTS)

##########################################
# 'helm upgrade'
dry-upgrade: dry-upgrade-base clean-tmp
dry-upgrade-base: req-params repo deps
	set -eu; helm upgrade "$(HELM_RELEASE)" "$(HELM_CHART)" \
        --install $(HELM_UPGRADE_OPTS) --dry-run=server
upgrade: upgrade-base clean-tmp
upgrade-base: req-params repo deps
	set -eu; helm upgrade "$(HELM_RELEASE)" "$(HELM_CHART)" \
        --install $(HELM_UPGRADE_OPTS)

##########################################
# 'helm package'
package: req-params repo clean deps
	set -eu; helm package --dependency-update \
        --app-version="$(git rev-parse HEAD || true)" \
        "$(HELM_CHART)"

##########################################
# 'helm uninstall'
uninstall: req-params repo
	set -eu; helm uninstall "$(HELM_RELEASE)" --namespace "$(K8S_NS)" --debug

##########################################
# 'helm lint'
# Currently not enabling --with-subcharts since its noisy
lint: req-params repo
	set -eu; helm lint --quiet --values "$(HELM_VALUES)"

##########################################
# 'make pin-versions'
# This command handles snapshotting container versions as well as pulling a
# specific Git SHA hash of pinned versions for rollbacks.
# Run this before you deploy in order to store the versions of containers
# at deploy time.
# 
# $ROOT variable should come from Makefile.inc / Makefile that called this Makefile,
# and must point at the root directory of this Git repository.
# $PINNED_VALUES_YAML must be relative to the Git repository root directory for the git
# command, so we remove '$ROOT/' from it in case it's not relative already.
dry-pin-versions:
pin-versions: req-params
	set -eu ; \
    if [ -n "$${PIN_VERSION_DIGEST:-}" ] ; then \
        pin_ver_rel="$${PINNED_VALUES_YAML##$$ROOT/}" ; \
        git show "$${PIN_VERSION_DIGEST}:$${pin_ver_rel}" > "$${PINNED_VALUES_YAML}" ; \
    else \
        "$$ROOT/helm/bin/manage-values.sh" -f "$${PINNED_VALUES_YAML}" pin_version containers "$${HELM_CHART}"; \
    fi


##########################################
# 'make commit-versions'
# Commit the pinned versions that were used at deploy time
commit-versions: commit-pin-versions 
commit-pin-versions:
# Once Helm deploy is successful, record what the deployed release of the Helm chart was,
# and merge it into the PINNED_VALUES_YAML file. Then commit the file to Git.
# We have to pass the K8S_NS because the ci/cd job won't necessarily set the namespace
# before running these tasks. The namespace is currently set in Makefile.inc.
commit-helm-release: req-params
	set -x ; "$$ROOT/helm/bin/manage-values.sh" -f "$${PINNED_VALUES_YAML}" pin_version chart "$${HELM_CHART}" "$${HELM_RELEASE}" "current" "$${K8S_NS}"
	"$$ROOT/bin/commit-file.sh" -m "Deploy succeeded, pinning versions [skip ci]" "$${PINNED_VALUES_YAML}"


##########################################
# 'make custom-deploy'
# Generate the custom values.yaml files to be uploaded as K8s secrets. Later on a CI/CD
# job will pick up the K8s secrets and apply them in Helm commands.

# Attempt to grab the custom-deploy values from Kubernetes cluster
# so we can use them in deploy later.
# To skip this step, set SKIP_HELM_USE_CUSTOM_VALUES=1
define helm_use_custom_values_func
if [ ! "$${SKIP_HELM_USE_CUSTOM_VALUES:-0}" = "1" ] ; then \
  tmpfile=$$(mktemp -t $$filename.XXXXXX) ; \
  "$$ROOT/helm/bin/custom-deploy.sh" \
      -C "$(HELM_CHART)" \
      -R "$(HELM_RELEASE)" \
      -N "$(K8S_NS)" \
      get_values "$$filename" 2>/dev/null 1>"$$tmpfile" ; \
  if [ $$? -ne 0 ] || [ ! -s "$$tmpfile" ] ; then rm -f "$$tmpfile" ; \
  else echo "$$tmpfile" ; fi ; \
fi
endef

# Use the above function to define a variable which points to a file with the
# custom values to deploy. Variable is empty if K8s secret not found.
DEPLOYSH_CUSTOM_DEPLOY ?= 1
ifeq ($(DEPLOYSH_CUSTOM_DEPLOY),1)
CUSTOM_HELM_VALUES = $(shell filename="values"; $(helm_use_custom_values_func) )
CUSTOM_PINNED_VALUES := $(shell filename="pinned-values"; $(helm_use_custom_values_func) )
# make sure to set DEPLOYSH_CUSTOM_DEPLOY=0 to prevent running this for sub-charts
export DEPLOYSH_CUSTOM_DEPLOY = 0
endif

yamlfileargs = $(HELM_VALUES)

# If CUSTOM_HELM_VALUES or CUSTOM_PINNED_VALUES were found
# (in a k8s secret), use those as the values.yaml arguments
# to Helm. Otherwise, use HELM_EXTRA_VALUES and PINNED_VALUES_YAML.
# This allows the k8s secret to override the Helm configuration we
# would otherwise use, enabling the deployment of custom values.
# (combining both sets of values would cause conflicts, so we only
#  accept one set or the other)

ifneq ($(CUSTOM_HELM_VALUES),)
yamlfileargs += $(CUSTOM_HELM_VALUES)
else
yamlfileargs += $(HELM_EXTRA_VALUES)
endif

ifneq ($(CUSTOM_PINNED_VALUES),)
yamlfileargs += $(CUSTOM_PINNED_VALUES)
else
yamlfileargs += $(PINNED_VALUES_YAML)
endif

dry-custom-deploy:
	"$$ROOT/helm/bin/custom-deploy.sh" \
        -n \
        -C "$(HELM_CHART)" \
        -R "$(HELM_RELEASE)" \
        -N "$(K8S_NS)" \
        upload values pinned-values

custom-deploy:
	"$$ROOT/helm/bin/custom-deploy.sh" \
        -C "$(HELM_CHART)" \
        -R "$(HELM_RELEASE)" \
        -N "$(K8S_NS)" \
        upload values pinned-values

HELM_DIFF_UPGRADE_OPTS = \
    --install \
    --show-secrets \
    --normalize-manifests \
    --three-way-merge \
    --output dyff \
    --color
# More options:
#    --detailed-exitcode to exit with error when a change is detected
#    --three-way-merge is used to pull k8s state and include that in the diff

ifneq ($(HELM_CHART_VERSION),)
HELM_DIFF_UPGRADE_OPTS += --version="$(HELM_CHART_VERSION)"
endif
HELM_DIFF_UPGRADE_OPTS += $(foreach file,$(yamlfileargs),-f "$(file)")

##########################################
# 'make dry-diff-upgrade'
dry-diff-upgrade: dry-diff-upgrade-base
dry-diff-upgrade-base: req-params repo deps
	set -eu; \
        kubectl config set-context --current --namespace="$(K8S_NS)" ; \
        env HELM_DIFF_USE_INSECURE_SERVER_SIDE_DRY_RUN=true \
            HELM_DIFF_USE_UPGRADE_DRY_RUN=true \
            helm diff upgrade \
            $(HELM_DIFF_UPGRADE_OPTS) --dry-run=server \
                "$(HELM_RELEASE)" "$(HELM_CHART)"

##########################################
# 'make diff-upgrade'
# 
# The env vars below are needed to pull the k8s state from the cluster,
# for 'lookup'-using templates. Otherwise they may show removed entries.
diff-upgrade: dry-diff-upgrade-base
diff-upgrade-base: req-params repo deps
	set -eu; \
        kubectl config set-context --current --namespace="$(K8S_NS)" ; \
        env HELM_DIFF_USE_INSECURE_SERVER_SIDE_DRY_RUN=true \
            HELM_DIFF_USE_UPGRADE_DRY_RUN=true \
            helm diff upgrade \
                $(HELM_DIFF_UPGRADE_OPTS) \
                "$(HELM_RELEASE)" "$(HELM_CHART)"


##########################################
# clean up files
clean-tmp:
	rm -v -f "$(CUSTOM_HELM_VALUES)" "$(CUSTOM_PINNED_VALUES)"
clean:
	HELM_CHART="$${HELM_CHART:-.}" ; \
	rm -f "$$HELM_CHART"/*.tgz ; \
	rm -f "$$HELM_CHART"/charts/*.tgz "$$HELM_CHART"/charts/*/*.tgz "$$HELM_CHART/"charts/*/*/*.tgz ; \
	rm -f "$$HELM_CHART"/Chart.lock "$$HELM_CHART"/charts/*/Chart.lock ; \
	rmdir -v "$$HELM_CHART"/charts/*/charts "$$HELM_CHART"/charts || true

