#!/bin/bash

CLUSTER_NAME=""
VPC_CIDR=""
# Define subnet ids with comma separated
SUBNET_IDS=""
AWS_REGION=""

rosa create account-roles \
  --prefix ${CLUSTER_NAME} \
  --mode auto \
  --yes

OIDC_CONFIG_ID=`rosa create oidc-config --mode=auto  --yes | grep oidc-provider | cut -f3 -d/ | cut -f1 -d\'`
AWS_ACCOUNT_NUMBER=`aws sts get-caller-identity | grep Account | cut -f2 -d: |  cut -f1 -d,| cut -f2 -d\"`

rosa create operator-roles \
  --prefix ${CLUSTER_NAME}\
  --oidc-config-id $OIDC_CONFIG_ID \
  --installer-role-arn arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${CLUSTER_NAME}-Installer-Role \
  --mode auto \
  --yes

rosa create cluster \
  --role-arn arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${CLUSTER_NAME}-Installer-Role \
  --support-role-arn arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${CLUSTER_NAME}-Support-Role \
  --worker-iam-role arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${CLUSTER_NAME}-Worker-Role \
  --controlplane-iam-role arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${CLUSTER_NAME}-ControlPlane-Role \
  --oidc-config-id ${OIDC_CONFIG_ID} \
  --operator-roles-prefix ${CLUSTER_NAME} \
  --private-link \
  --sts \
  --mode auto \
  --multi-az \
  --cluster-name ${CLUSTER_NAME} \
  --machine-cidr ${VPC_CIDR} \
  --subnet-ids ${SUBNET_IDS} \
  --yes \
  --region ${AWS_REGION}
