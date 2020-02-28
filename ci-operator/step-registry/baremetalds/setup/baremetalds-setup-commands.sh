#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
secret_dir=/tmp/secret

export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey
export PULL_SECRET_PATH=${cluster_profile}/pull-secret
export PACKET_AUTH_TOKEN=${cluster_profile}/.packetcrd
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
export PACKET_PROJECT_ID=b3c1623c-ce0b-45cf-9757-c61a71e06eac
export CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"

echo "************ baremetalds setup command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Terraform setup and init for packet server
terraform_home=${ARTIFACT_DIR}/terraform
mkdir -p ${terraform_home}
cd ${terraform_home}

cat > ${terraform_home}/terraform.tf <<-EOF
provider "packet" {
}

resource "packet_device" "server" {
  count            = "1"
  project_id       = "$PACKET_PROJECT_ID"
  hostname         = "ipi-$CLUSTER_NAME"
  plan             = "m2.xlarge.x86"
  facilities       = ["sjc1", "ewr1"]
  operating_system = "centos_7"
  billing_cycle    = "hourly"
}
EOF

terraform init

# Packet returns transients errors when creating devices.
# example, `Oh snap, something went wrong! We've logged the error and will take a look - please reach out to us if you continue having trouble.`
# therefore the terraform apply needs to be retried a few time before giving up.
rc=1
for r in {1..5}; do terraform apply -auto-approve && rc=0 && break ; done
if test "${rc}" -eq 1; then echo "failed to create the infra resources"; sleep 1; fi

# Sharing artifacts required by teardown
jq -r '.modules[0].resources["packet_device.server"].primary.attributes.access_public_ipv4' terraform.tfstate > ${secret_dir}/packet-server-ip

export HOME=${secret_dir}/nss_wrapper
mkdir -p $HOME

# Note: libnss_wrapper.so and mock-nss.sh are relative to SHARED_DIR because they've been copied by the previous nss-wrapper-hack step
export NSS_WRAPPER_PASSWD=$HOME/passwd NSS_WRAPPER_GROUP=$HOME/group NSS_USERNAME=nsswrapper NSS_GROUPNAME=nsswrapper LD_PRELOAD=${SHARED_DIR}/libnss_wrapper.so
bash ${SHARED_DIR}/mock-nss.sh

export IP=$(cat ${secret_dir}/packet-server-ip)
echo "Packet server IP is ${IP}"

# Sharing terraform artifacts required by teardown
cp -R ${terraform_home} ${secret_dir}

#########

# for x in $(seq 10) ; do
#     test $x == 10 && exit 1
#     ssh $SSHOPTS root@$IP hostname && break
#     sleep 10
# done

# scp $SSHOPTS ${PULL_SECRET_PATH} root@$IP:pull-secret
# timeout -s 9 175m ssh $SSHOPTS root@$IP bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

# set -ex

# yum install -y git

# # python2-cryptography needs to come from delorean-master-testing, priority of packet.repo overrides it
# # remove the priority and instead ensure the packet repo is named first alphabetically
# # this way it is prefered but it isn't a hard override when newer versions are found elsewhere
# sed -i -e 's/priority.*//g' /etc/yum.repos.d/packet.repo
# sed -i -e 's/packet-/a_packet-/g' /etc/yum.repos.d/packet.repo

# rm -rf /tmp/artifacts
# mkdir -p /tmp/artifacts

# if [ ! -e dev-scripts ] ; then
#   git clone https://github.com/openshift-metal3/dev-scripts.git
# fi
# cd dev-scripts

# set +x
# echo "export PULL_SECRET='\$(cat /root/pull-secret)'" > /root/dev-scripts/config_root.sh
# set -x

# curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/4.4/linux/oc.tar.gz | tar -C /usr/bin -xzf -

# #echo "export OPENSHIFT_RELEASE_IMAGE=$MIRROR_BASE:latest" >> /root/dev-scripts/config_root.sh
# echo "export OPENSHIFT_RELEASE_IMAGE=registry.svc.ci.openshift.org/ocp/release:4.4.0-0.nightly-2020-01-29-012724" >> /root/dev-scripts/config_root.sh
# echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
# echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
# echo "export MIRROR_IMAGES=true" >> /root/dev-scripts/config_root.sh

# echo 'export KUBECONFIG=/root/dev-scripts/ocp/auth/kubeconfig' >> /root/.bashrc

# if [ ! -e /opt/dev-scripts/pool ] ; then
#   mkdir -p /opt/dev-scripts/pool
#   mount -t tmpfs -o size=100G tmpfs /opt/dev-scripts/pool
# fi

# timeout -s 9 105m make

# EOF

# mkdir -p ${ARTIFACT_DIR}/installer/auth
# scp $SSHOPTS root@$IP:./dev-scripts/ocp/auth/kubeconfig ${ARTIFACT_DIR}/installer/auth/kubeconfig




