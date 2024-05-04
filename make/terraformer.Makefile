ROOT ?= $(shell git rev-parse --show-toplevel)

include $(ROOT)/make/asdf.Makefile
TERRAFORMER_HELP_TARGETS := tfr-help-general tfr-help-asdf tfr-help-init tfr-help-import-google
TERRAFORMER_TARGETS := all tfr-help tfr-asdf tfr-init tfr-import-google tfr-providers-lock

GCP_REGION := us-west1

# This isn't an exhaustive list; it's just most of the resources we probably use today.
GOOGLE_RESOURCES=addresses autoscalers backendBuckets backendServices cloudFunctions cloudsql disks externalVpnGateways dns firewall forwardingRules gcs gke globalAddresses globalForwardingRules healthChecks httpHealthChecks iam images instanceGroupManagers instanceGroups instanceTemplates instances interconnectAttachments kms logging memoryStore monitoring networks nodeGroups nodeTemplates project pubsub regionAutoscalers regionBackendServices regionDisks regionHealthChecks regionInstanceGroups regionSslCertificates regionTargetHttpProxies regionTargetHttpsProxies regionUrlMaps reservations resourcePolicies regionInstanceGroupManagers routers routes schedulerJobs securityPolicies sslCertificates sslPolicies subnetworks targetHttpProxies targetHttpsProxies targetInstances targetPools targetSslProxies targetTcpProxies targetVpnGateways urlMaps vpnTunnels


.PHONY: $(TERRAFORMER_HELP_TARGETS) $(TERRAFORMER_TARGETS)


tfr-help: $(TERRAFORMER_HELP_TARGETS)
tfr-help-general:
	@echo "Make targets for terraformer:"

tfr-help-asdf:
	@echo "   tfr-asdf                 Install ASDF plugins for terraform and terraformer"
tfr-asdf: asdf-add-install-plugin
	# We install all plugins because asdf install errors out if some plugins aren't installed

tfr-help-init:
	@echo "   tfr-init                 Run 'terraform init'"
tfr-init:
	set -eu ; cd $$TERRAFORMER_ROOT ; timeout --foreground -v 30m terraform init

tfr-help-import-google:
	@echo "   tfr-import-google        Run 'terraformer import google [...]'"
tfr-import-google: $(GOOGLE_RESOURCES)
	@echo "All done importing google resources."

tfr-help-providers-lock:
	@echo "   tfr-providers-lock       Run 'terraform providers lock'"
tfr-providers-lock:
	terraform providers lock

# WARNING: this will take *any* target passed to make and execute it as a --resources= option
# Use a timeout because 'iam' and 'logging' like to hang forever :(
% :
	set -eu ; cd $$TERRAFORMER_ROOT ; timeout --foreground -v 30m terraformer import google \
        --projects=$$GCP_PROJECT \
        --regions=$$GCP_REGION \
        --resources=$@ \
        --retry-number 1 \
        --retry-sleep-ms 10 \
        --compact \
        --verbose

