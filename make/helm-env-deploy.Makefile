include Makefile.inc

export

# EXTRA_PRE_DEPLOY_TARGETS is set in Makefile.inc so that we can run
# targets before the deploy step, like 'delete-old-populatesql-job'
# (defined in the Makefile.inc).

dry-deploy: auth-to-gke-cluster $(EXTRA_PRE_DEPLOY_TARGETS)
	make -C $(CD_DIR) clean $(EXTRA_DEPLOY_TARGETS) dry-upgrade

deploy: auth-to-gke-cluster $(EXTRA_PRE_DEPLOY_TARGETS)
	make -C $(CD_DIR) clean $(EXTRA_DEPLOY_TARGETS) upgrade

dry-custom-deploy: auth-to-gke-cluster
	make -C $(CD_DIR) dry-custom-deploy

custom-deploy: auth-to-gke-cluster
	make -C $(CD_DIR) custom-deploy

# Note on pinning versions and rollbacks:
#   pin-versions is run right before upgrade. This is safe, because the pin-versions
#   command will reuse an existing PIN_VERSION_DIGEST's file (for rollbacks) if it's passed.
#   Otherwise it will generate a new pinned version file, which if deploy is successful, will
#   get committed (for reference by a rollback).
# 
# Makefile.inc must define these values:
#   PINNED_VALUES_YAML = FULLY/QUALIFIED/PATH/TO/pinned-values.yaml
#   EXTRA_DEPLOY_TARGETS := pin-versions
# If they are not defined in Makefile.inc, pin-versions is never run.
# 
pin-versions:
	make -C $(CD_DIR) pin-versions

commit-helm-release:
	make -C $(CD_DIR) commit-helm-release

uninstall: auth-to-gke-cluster
	make -C $(CD_DIR) uninstall

help:
	make -C $(CD_DIR) help-targets

template: auth-to-gke-cluster
	make -C $(CD_DIR) template

dry-diff: auth-to-gke-cluster
	make -C $(CD_DIR) dry-diff-upgrade
diff: auth-to-gke-cluster
	make -C $(CD_DIR) diff-upgrade

# This is how we configure K8s access before running the Helm install.
# This ensures we have a valid kubectl config and the correct context
# selected for this particular cluster we're deploying to.
# 
# It's simpler to do this right at the helm deploy step, rather than have
# a CI job doing it, or some other external step which might be missed
# before this step.
# 
# We may also need to run Terraform before or after the Helm deploy steps,
# and use the same kubectl config, so this can be used for that too.
# 
auth-to-gke-cluster:
	@export DIRENVSH_STOPDIR="$(ROOT)/env" DIRENVSH_RC="terraform.sh.tfvars" ; \
    eval "$$($(ROOT)/bin/rev-load-vars.sh -s)" ; \
    zone="$${gke_cluster_zones##[ }" ; zone="$${zone%% ]}" ; export zone ; \
    context="$$(kubectl config current-context)" ; \
    wantcontext="gke_$${gcp_project_id}_$${zone}_$${gke_cluster_name}" ; \
    if [ ! "$$context" = "$$wantcontext" ] ; then \
         gcloud --project "$$gcp_project_id" \
            container clusters get-credentials "$$gke_cluster_name" \
            --zone "$$zone" ; \
    fi
