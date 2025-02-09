#!/usr/bin/env bash

# Copyright 2018 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o errexit
set -o nounset
set -o pipefail

source "$(dirname "${BASH_SOURCE}")/util.sh"

ROOT_DIR="$(cd "$(dirname "$0")/.." ; pwd)"
WORKDIR=$(mktemp -d)
NS="${KUBEFED_NAMESPACE:-kube-federation-system}"
CHART_FEDERATED_PROPAGATION_DIR="${CHART_FEDERATED_PROPAGATION_DIR:-charts/kubefed}"
TEMP_CRDS_YAML="/tmp/kubefed-crds.yaml"

OS=`uname`
SED=sed
if [ "${OS}" == "Darwin" ];then
  if ! which gsed > /dev/null ; then
    echo "gsed is required by this script. It can be installed via homebrew (https://brew.sh)"
    exit 1
  fi
  SED=gsed
fi

# Check for existence of kube-apiserver and etcd binaries in bin directory
if [[ ! -f ${ROOT_DIR}/bin/etcd || ! -f ${ROOT_DIR}/bin/kube-apiserver ]];
then
  echo "Missing 'etcd' and/or 'kube-apiserver' binaries in bin directory. Call './scripts/download-binaries.sh' to download them first"
  exit 1
fi

# Remove existing generated crds to ensure that stale content doesn't linger.
rm -f ./config/crds/*.yaml

# Generate CRD manifest files
(cd ${ROOT_DIR}/tools && GOBIN=${ROOT_DIR}/bin go install sigs.k8s.io/controller-tools/cmd/controller-gen)
${ROOT_DIR}/bin/controller-gen crd:trivialVersions=true paths="./pkg/apis/..." output:crd:artifacts:config=config/crds

# Merge all CRD manifest files into one file
echo "" > ${TEMP_CRDS_YAML}
for filename in ./config/crds/*.yaml; do
  # Remove unwanted kubebuilder annotation
   ${SED} '/controller-gen.kubebuilder.io/d; /annotations:/d' $filename >> ${TEMP_CRDS_YAML}
done

mv ${TEMP_CRDS_YAML} ./charts/kubefed/charts/controllermanager/crds/crds.yaml

# Generate kubeconfig to access kube-apiserver. It is cleaned when script is done.
cat <<EOF > ${WORKDIR}/kubeconfig
apiVersion: v1
clusters:
- cluster:
    server: 127.0.0.1:8080
  name: development
contexts:
- context:
    cluster: development
    user: ""
  name: kubefed
current-context: ""
kind: Config
preferences: {}
users: []
EOF

# Start kube-apiserver to generate CRDs
${ROOT_DIR}/bin/etcd --data-dir ${WORKDIR} --log-output stdout > ${WORKDIR}/etcd.log 2>&1 &
util::wait-for-condition 'etcd' "curl http://127.0.0.1:2379/version &> /dev/null" 30

${ROOT_DIR}/bin/kube-apiserver --etcd-servers=http://127.0.0.1:2379 --service-cluster-ip-range=10.0.0.0/16 --cert-dir=${WORKDIR} 2> ${WORKDIR}/kube-apiserver.log &
util::wait-for-condition 'kube-apiserver' "kubectl --kubeconfig ${WORKDIR}/kubeconfig --context kubefed get --raw=/healthz &> /dev/null" 60

# Generate YAML templates to enable resource propagation for helm chart.
echo -n > ${CHART_FEDERATED_PROPAGATION_DIR}/templates/federatedtypeconfig.yaml
echo -n > ${CHART_FEDERATED_PROPAGATION_DIR}/crds/crds.yaml
for filename in ./config/enabletypedirectives/*.yaml; do
  full_name=${CHART_FEDERATED_PROPAGATION_DIR}/templates/$(basename $filename)

  ./bin/kubefedctl --kubeconfig ${WORKDIR}/kubeconfig enable -f "${filename}" --kubefed-namespace="${NS}" --host-cluster-context kubefed -o yaml > ${full_name}
  $SED -n '/^---/,/^---/p' ${full_name} >> ${CHART_FEDERATED_PROPAGATION_DIR}/templates/federatedtypeconfig.yaml
  $SED -i '$d' ${CHART_FEDERATED_PROPAGATION_DIR}/templates/federatedtypeconfig.yaml

  echo "---" >> ${CHART_FEDERATED_PROPAGATION_DIR}/crds/crds.yaml
  $SED -n '/^apiVersion: apiextensions.k8s.io\/v1/,$p' ${full_name} >> ${CHART_FEDERATED_PROPAGATION_DIR}/crds/crds.yaml

  rm ${full_name}
done

# Clean kube-apiserver daemons and temporary files
kill %1 # etcd
kill %2 # kube-apiserver
rm -fr ${WORKDIR}
echo "Helm chart synced successfully"
