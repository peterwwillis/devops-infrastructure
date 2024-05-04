#!/usr/bin/env python3
# circleci-ctl.py
# 
# CircleCI API references:
#  - https://circleci.com/docs/api/v1/index.html
#  - https://circleci.com/docs/api/v2/index.html
#  - https://circleci.com/docs/api-developers-guide/

import os
import sys
import csv
import requests
import json
import logging
import urllib.parse
from collections import defaultdict

circle_token_name = os.environ.get("CIRCLECI_TOKEN_VAR_NAME", "CIRCLE_TOKEN")

circle_api_base_url = "https://circleci.com/api"

DEBUG = int(os.environ.get("DEBUG", "0"))
if DEBUG: logging.basicConfig(level=logging.DEBUG)
else: logging.basicConfig(level=logging.INFO)

headers = {}

class Struct:
    """ Struct for turning a dict into an object """
    def __init__(self, **entries):
        self.__dict__.update(entries)

class ManageCircle(object):
    """ Class for managing CircleCI functionality """
    csvw = None
    api_ver_map = {
        '2': { 'bitbucket': 'bb', 'bb': 'bb' },
        '1': { 'bitbucket': 'bitbucket', 'bb': 'bitbucket' }
    }
    opts = None

    def __init__(self, opts=None):
        self.opts = opts

    def vcs(self, arg, ver):
        """ Function to convert the version-control argument between the formats
            expected for CircleCI API v1 or v2.
        """
        return self.api_ver_map[ver][arg]

    @staticmethod
    def load_list(arg):
        """ Pass an argument and convert it into a list.
            If the argument begins with "file://", the argument is opened as a file
            and its contents are split by line into a list.
            If the argument is "-", standard input is split by line into a list.
            Otherwise the argument is taken as a string and split by ',' into a list.
        """
        # arg can be a literal string, or a "file:///path/to/a/file", or "-" to read from stdin.
        # returns a list.
        args=[arg]
        if arg.startswith("file://"):
            with open(arg[7:]) as f:
                args = f.read().splitlines()
        elif arg == "-":
            args = sys.stdin.read().splitlines()
        else:
            args = arg.split(',')
        return args

    def post_api_json(self, url, payload):
        """ Send an HTTP POST with a JSON payload """
        my_headers = headers.copy()
        my_headers['Content-Type'] = 'application/json'
        try:
            response = requests.post(url, headers=my_headers, data=payload)
        except:
            logging.error( ("Error deleting page '%s': '%s'" % (url, response)) )
            return(None)
        return response.json()

    def delete_api_json(self, url):
        """ Send an HTTP DELETE """
        try:
            response = requests.api.delete(url, headers=headers)
        except:
            logging.error( ("Error deleting page '%s': '%s'" % (url, response)) )
            return(None)
        return response.json()

    def get_api_json(self, urlstr, apiver):
        """ Generator that sends an HTTP GET expecting a JSON payload.
            If 'next_page_token' is found in the JSON, request the
            page again but adding the token with '&page-token=%s' to
            the request.
            Pass --maxpages=N and --limit=N to override the defaults
            for pagination.
        """
        maxpages = 10
        if hasattr(self.opts, 'maxpages'):
            maxpages = int(self.opts.maxpages)
        url = circle_api_base_url + "/v" + apiver + "/" + urlstr[:]
        next_page_token = None
        next_page_url = url[:]
        counter=1
        while next_page_url is not None:
            try:
                response = requests.get(next_page_url, headers=headers)
                page_json = response.json()
                logging.debug( json.dumps(page_json) )
            except:
                logging.error( ("Error getting page '%s': %s" % (next_page_url,response)) )
                return(None)

            yield page_json

            if apiver == "2":
                next_page_url = None
                if 'next_page_token' in page_json:
                    next_page_token = page_json.get('next_page_token', None)
                    if next_page_token != None:
                        next_page_url = url[:] + "&page-token=%s" % next_page_token
            else:
                limit = 20
                if hasattr(self.opts, 'limit'):
                    limit = self.opts.limit
                next_page_url = url[:] + ("&limit=%s&offset=%i" % (limit, counter))

            if counter == maxpages:
                break
            counter = counter + 1

    def get_project_vars(self, args):
        """ Get environment variables assigned to the project. 
            Returns a CSV file.
        """
        vcs, org, projects = args[0], args[1], self.load_list(args[2])
        self.csvw = csv.writer(sys.stdout, quoting=csv.QUOTE_NONNUMERIC)
        self.csvw.writerow( [ "vcs", "org", "project", "name", "value" ] )
        for proj in projects:
            url = "project/%s/%s/%s/envvar" % (vcs, org, proj)
            for j in self.get_api_json(url, "2"):
                if j is None: continue
                if not 'items' in j: continue
                for key in j['items']:
                    self.csvw.writerow( [ vcs, org, proj, key['name'], key['value'] ] )

    def _get_pipelines(self, args):
        """ Get pipelines for a particular project.
            Can pass 'branch' as optional argument.
            Returns an array of dicts.
        """
        rows = []
        apivcs = self.vcs(args.vcs, "2")
        for project in self.load_list(args.projects):
            branchpostfix = ""
            if hasattr(args, 'branch'):
                branchpostfix = "branch=%s&" % urllib.parse.quote_plus(args.branch)
            url = "project/{vcs}/{org}/{project}/pipeline?{branchpostfix}"
            urlfmt = url.format(
                vcs=apivcs, org=args.org, project=project, branchpostfix=branchpostfix
            )
            for j in self.get_api_json(urlfmt, "2"):
                if j is None or not 'items' in j:
                    continue
                for key in j['items']:
                    rows.append({"vcs":args.vcs, "org":args.org, "project":project, "branch":branchpostfix, "item":key})
        return rows

    def get_pipelines(self, args):
        """ Runs _get_pipelines and dumps the result as JSON """
        rows = self._get_pipelines(args)
        print(json.dumps(rows))

    def _get_project_jobs(self, args):
        """ Get the jobs for a particular project.
            Can pass optional 'branch' and 'filter' arguments.
            Filter values: "completed", "successful", "failed", "running".
            Returns an array of dicts.
        """
        rows = []
        apivcs = self.vcs(args.vcs, "1")
        for project in self.load_list(args.projects):
            branchpostfix, filterpostfix = "", ""
            if hasattr(args, 'branch'):
                branchpostfix = "/tree/%s" % urllib.parse.quote_plus(args.branch)
            if hasattr(args, 'filter'):
                filterpostfix = "&filter=%s" % urllib.parse.quote_plus(args.filter)
            url = "project/{vcs}/{org}/{project}{branchpostfix}?{filterpostfix}"
            urlfmt = url.format(
                vcs=apivcs, org=args.org, project=project, branchpostfix=branchpostfix, filterpostfix=filterpostfix
            )
            for j in self.get_api_json(urlfmt, "1.1"):
                if j is None: continue
                for key in j:
                    rows.append({ "vcs":args.vcs, "org":args.org, "project":project, "branch":branchpostfix, "item":key })
        return rows

    def get_project_jobs(self, args):
        """ Runs _get_project_jobs and dumps the result as JSON """
        rows = self._get_project_jobs(args)
        print(json.dumps(rows))

    def _get_workflow(self, args):
        """ Get the data for a particular workflow.
            Returns an array of dicts.
        """
        rows = []
        url = "workflow/{workflow}"
        urlfmt = url.format( workflow=args.workflow )
        for j in self.get_api_json(urlfmt, "2"):
            if j is None: continue
            vcs, org, project = "", "", ""
            if 'project_slug' in j:
                vcs, org, project = j['project_slug'].split("/")
            apivcs = vcs
            if len(vcs) > 0:
                apivcs = self.vcs(vcs, "1")
            rows.append({ "vcs":apivcs, "org":org, "project":project, "item":j })
        return rows

    def get_workflow(self, args):
        """ Runs _get_workflow and dumps the result as JSON """
        rows = self._get_workflow(args)
        print(json.dumps(rows))

    def _post_workflow(self, args):
        """ Post some data to a particular workflow.
            Returns data which is probably json.
        """
        url = "https://circleci.com/api/v2/workflow/{workflow}"
        data=None
        if hasattr(args, 'data'):
            data = args.data
        urlfmt = url.format( workflow=args.workflow )
        j = self.post_api_json(urlfmt, data)
        return j

    def post_workflow(self, args):
        """ Runs _post_workflow and dumps the result as JSON """
        result = self._post_workflow(args)
        print(json.dumps(result))

    def get_checkout_keys(self, args):
        """ get_checkout_keys(vcs, org, projects)
            Gets the checkout keys for a project.
            Project can be a single project, or a 'file:///path/to/a/file', or '-' to read from stdin.
        """
        vcs, org, projects = args[0], args[1], self.load_list(args[2])
        self.csvw = csv.writer(sys.stdout, quoting=csv.QUOTE_NONNUMERIC)
        self.csvw.writerow( [ "vcs", "org", "project", "key_type", "key_preferred", "key_created_at", "public_key", "key_fingerprint" ] )
        for proj in projects:
            url = "project/%s/%s/%s/checkout-key" % (vcs, org, proj)
            for j in self.get_api_json(url, "2"):
                if j is None: continue
                if not 'items' in j: continue
                for key in j['items']:
                    self.csvw.writerow( [ vcs, org, proj, key['type'], key['preferred'], key['created_at'], key['public_key'].rstrip(), key['fingerprint'] ] )

    def create_checkout_key(self, args):
        """ create_checkout_key(vcs, org, project)
            Creates a checkout key in a project.
        """
        vcs, org, project = args[0], args[1], args[2]
        url = "https://circleci.com/api/v2/project/%s/%s/%s/checkout-key" % (vcs, org, project)
        j = self.post_api_json(url, '{"type":"deploy-key"}')
        if 'fingerprint' in j:
            print("vcs='%s' org='%s' project='%s': Created key '%s'" % (vcs, org, project, j['fingerprint']))
        else:
            print("vcs='%s' org='%s' project='%s': Failed to create fingerprint: '%s'" % (vcs, org, project, j))

    def delete_checkout_key(self, args):
        """ delete_checkout_key(vcs, org, project, fingerprint)
            Deletes a checkout key for a project by fingerprint.
        """
        vcs, org, project, fingerprint = args[0], args[1], args[2], args[3]
        url = "https://circleci.com/api/v2/project/%s/%s/%s/checkout-key/%s" % (vcs, org, project, fingerprint)
        j = self.delete_api_json(url)
        print("vcs='%s' org='%s' project='%s': Deleted key '%s'" % (vcs, org, project, fingerprint))

    def rotate_checkout_key(self, args):
        """ rotate_checkout_key(vcs, org, project, fingerprint)
            Rotates a checkout key for a project by fingerprint.
        """
        vcs, org, project, fingerprint = args[0], args[1], args[2], args[3]
        self.delete_checkout_key(args)
        self.create_checkout_key(args)


def usage():
    usage_str = """Usage: %s COMMAND [OPTIONS]

Commands:

get_checkout_keys VCS ORG PROJECT
                    -   Gets all checkout keys for a project. PROJECT can be a single
                        project, or a "file:///path/to/a/file" to read projects from,
                        or "-" to read projects line-by-line from standard input.
                        Prints out a CSV file.

create_checkout_key VCS ORG PROJECT
                    -   Creates a deploy key in VCS / ORG / PROJECT

delete_checkout_key VCS ORG PROJECT FINGERPRINT
                    -   Deletes a checkout key FINGERPRINT

rotate_checkout_key VCS ORG PROJECT FINGERPRINT
                    -   Deletes a checkout key FINGERPRINT, then creates a new one.

get_project_vars VCS ORG PROJECT
                    -   List all the project-specific environment variables.
                        Prints out a CSV file.

get_project_jobs --vcs=bitbucket --org=ORG --projects=REPO [--branch=master]
                 [--filter=completed]
                    -   List all jobs under a project (repo). Filter values:
                            "completed", "successful", "failed", "running"

get_pipelines --vcs=bitbucket --org=ORG --projects=REPO [--branch=master]
                    -   List all pipelines under a project (repo)

get_workflow --workflow=12345678-xxxx-xxxx-xxxx-xxxxxxxxxxxx
             --workflow=12345678-xxxx-xxxx-xxxx-xxxxxxxxxxxx/job
                    -   Get the status of a workflow ID, or get the jobs of a workflow.

post_workflow --workflow=12345678-xxxx-xxxx-xxxx-xxxxxxxxxxxx/approve/JOBID
              --workflow=12345678-xxxx-xxxx-xxxx-xxxxxxxxxxxx/cancel
              --workflow=12345678-xxxx-xxxx-xxxx-xxxxxxxxxxxx/rerun --data='{"enable_ssh":false,"from_failed":false,"jobs":["xxxxxxxxxxxxx-xxxx-xxxx-xxxxxxxxxxxx"],"sparse_tree":false}'
                    -   Send a POST to a workkflow to approve or cancel a job or rerun a workflow.

""" % sys.argv[0]
    print(usage_str)
    exit(1)


def main():
    if len(sys.argv) < 2:
        usage()

    if not os.environ.get(circle_token_name):
        logging.error( ("You must pass environment variable %s" % circle_token_name) )
        exit(1)
    headers['Circle-Token'] = os.environ[circle_token_name]

    # turn sys.argv's '--foo=bar' into object 'opts' with attribute 'foo' returning ["bar"].
    # supports multiple uses of '--foo'
    d=defaultdict(list)
    for k, v in ((k.lstrip('-'), v) for k,v in (a.split('=') for a in sys.argv[2:])):
        d[k].append(v)
    for k in (k for k in d if len(d[k])==1):
        d[k] = d[k][0]
    opts = Struct(**d)

    o = ManageCircle(opts=opts)
    if sys.argv[1] == "get_checkout_keys":
        o.get_checkout_keys(sys.argv[2:])
    elif sys.argv[1] == "create_checkout_key":
        o.create_checkout_key(sys.argv[2:])
    elif sys.argv[1] == "delete_checkout_key":
        o.delete_checkout_key(sys.argv[2:])
    elif sys.argv[1] == "rotate_checkout_key":
        o.rotate_checkout_key(sys.argv[2:])
    elif sys.argv[1] == "get_project_vars":
        o.get_project_vars(sys.argv[2:])
    elif sys.argv[1] == "get_project_jobs":
        o.get_project_jobs(opts)
    elif sys.argv[1] == "get_pipelines":
        o.get_pipelines(opts)
    elif sys.argv[1] == "get_workflow":
        o.get_workflow(opts)
    elif sys.argv[1] == "post_workflow":
        o.post_workflow(opts)
    else:
        usage()

if __name__ == "__main__":
    main()
