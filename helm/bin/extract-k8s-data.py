#!/usr/bin/env python3
# extract-k8s-data.py - extract data from k8s manifests into a simpler structure

import os
import sys
import json
import shutil
import getopt
import hashlib
from pathlib import Path
from string import Template

from ruamel.yaml import YAML
from ruamel.yaml.compat import StringIO

class MyYAML(YAML):
    def dump(self, data, stream=None, **kw):
        inefficient = False
        if stream is None:
            inefficient = True
            stream = StringIO()
        YAML.dump(self, data, stream, **kw)
        if inefficient:
            return stream.getvalue()

class MakeHelmChartTemplate(object):
    yaml = None
    docs = []
    deployments = []
    secrets = []
    k8s_manifest = []
    dump_json = False
    dump_yaml = True

    def load_yaml(self, file):
        print("load_yaml('%s')" % file)
        with open(file, 'r') as f:
            self.filedata = f.read()
        self.yaml = MyYAML(typ='safe')
        for doc in self.yaml.load_all(self.filedata):
            self.docs.append(doc)

    def load_k8s_manifests(self):
        print("load_k8s_manifests()")
        for f in self.k8s_manifest:
            self.load_yaml(f)

    def process_manifests(self):
        print("process_manifests()")
        if len(self.k8s_manifest) > 0 and len(self.docs) < 1:
            self.load_k8s_manifests()
        for doc in self.docs:
            if not 'apiVersion' in doc:
                raise Exception("no 'apiVersion' found in manifest (%s)" % doc)
            if not 'kind' in doc:
                raise Exception("no 'kind' found in manifest (%s)" % doc)
            if doc['kind'].lower() == "deployment":
                self.load_deployments(doc)
            elif doc['kind'].lower() == "secret":
                self.load_secrets(doc)
            else:
                print("Warning: Skipping unknown manifest kind '%s'" % doc['kind'])

    def load_deployments(self, doc):
        print("load_deployments()" % doc)
        if not 'spec' in doc:
            raise Exception("'spec' missing from deployment")
        spec = doc['spec']
        if not 'template' in spec:
            raise Exception("'template' missing from spec")
        else:
            template = spec['template']
        if not 'spec' in template:
            exception("'spec' missing from template")
        templatespec = template['spec']
        if not 'containers' in templatespec:
            raise Exception("'containers' missing from templatespec")
        for container in templatespec['containers']:
            collect = {}
            if 'volumes' in templatespec:
                collect['volumes'] = self.yaml.dump({ "volumes": templatespec['volumes'] })
            collect['name'] = container['name']
            collect['image'] = container['image']
            if 'ports' in container and len(container['ports']) > 0:
                ports = container['ports'].copy()
                port = ports.pop(0)
                collect['port'] = port['containerPort']
                if len(ports) > 0:
                    c, newports = 0, []
                    for addlport in ports:
                        c+=1
                        newport = {}
                        if 'name' in addlport:
                            newport['name'] = name
                        else:
                            newport['name'] = collect['name'] + ("-%i" % c)
                        # named ports can only be 15 chars :(
                        if 'name' in newport and len(newport['name']) > 15:
                            hashval = hashlib.sha1(newport['name'].encode()).hexdigest()
                            newport['name'] = "port-" + hashval[0:7]
                        newport['containerPort'] = addlport['containerPort']
                        newport['protocol'] = "TCP"
                        newports.append(newport)
                    collect['additionalPorts'] = self.yaml.dump({ "additionalPorts": newports.copy() })
            if 'volumeMounts' in container:
                collect['volume-mounts'] = self.yaml.dump({ "volumeMounts": container['volumeMounts'] })
            if 'env' in container:
                collect['env'] = self.yaml.dump( container['env'] )
            if 'resources' in container:
                collect['resources'] = self.yaml.dump({ "resources": container['resources'] })
            for probe in ('readinessProbe', 'livenessProbe'):
                if probe in container:
                    crp = container[probe]
                    rp = {}
                    for arg in ('initialDelaySeconds', 'periodSeconds', 'timeoutSeconds', 'successThreshold', 'failureThreshold'):
                        if arg in crp:
                            rp[arg] = crp[arg]
                    if 'httpGet' in crp:
                        rp['probeType'] = 'httpGet'
                        rp['path'] = crp['httpGet']['path']
                        rp['port'] = crp['httpGet']['port']
                    elif 'tcpSocket' in crp:
                        rp['probeType'] = 'tcpSocket'
                        rp['port'] = crp['tcpSocket']['port']
                    elif 'exec' in crp:
                        rp['probeType'] = 'exec'
                        rp['command'] = crp['exec']['command']
                    collect[probe] = self.yaml.dump({ probe: rp })

            self.deployments.append(collect)

    def load_secrets(self, doc):
        print("load_secrets()")
        collect = {}
        if not 'metadata' in doc:
            raise Exception("'metadata' missing from secret")
        metadata = doc['metadata']
        collect['name'] = metadata['name']
        if not 'type' in doc:
            raise Exception("'type' missing from secret")
        collect['type'] = doc['type']
        if not 'data' in doc:
            raise Exception("'data' missing from secret")
        data = doc['data']
        collect['secretData'] = self.yaml.dump( data )

        self.secrets.append(collect)


    def cmd_dump_all(self):
        self.dump_data(self.deployments, "deployment-container-")
        self.dump_data(self.secrets, "secret-")

    def dump_data(self, data, fileprefix):
        for i in data:
            fn = fileprefix + "%s" % i['name']
            if self.dump_json == True:
                fn = fn + ".json"
            elif self.dump_yaml == True:
                fn = fn + ".yaml"
            with open(fn, "w") as f:
                print("creating file '%s'" % fn)
                if self.dump_json == True:
                    json.dump(i, f, sort_keys=True, indent=4)
                elif self.dump_yaml == True:
                    self.yaml.dump(i, f)

def usage():
    usage = """Usage: %s [OPTIONS] COMMAND [ARGS ..]

Commands:
    dump-all MANIFEST[..]               Parses all Kubernetes manifests passed and
                                        dumps their data into new files in the format
                                        chosen

Options:
    -j,--json                   Dump data in JSON format
    -y,--yaml                   Dump data in YAML format
""" % sys.argv[0]
    print(usage)
    exit(1)

def main(argv):
    o = MakeHelmChartTemplate()
    opts, args = getopt.getopt(argv, "jy", ["--json","--yaml"])
    for opt, arg in opts:
        if opt in ("-j","--json"):
            o.dump_json = True
        elif opt in ("-y","--yaml"):
            o.dump_yaml = True
    if len(args) < 1:
        usage()
    if args[0] == "dump-all":
        if len(args) < 2:
            raise Exception("please pass one or more MANIFEST files")
        [o.k8s_manifest.append(x) for x in args[1:]]
        o.process_manifests()
        o.cmd_dump_all()
    else:
        usage()

if __name__ == "__main__":
    main(sys.argv[1:])

