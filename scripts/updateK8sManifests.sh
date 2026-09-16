#!/bin/bash
set -x

REPO_URL="https://dev.azure.com/rahulraval/voting-app/_git/voting-app"

git config --global http.extraheader "AUTHORIZATION: bearer ${SYSTEM_ACCESSTOKEN}"

git clone "$REPO_URL" /tmp/temp_repo

cd /tmp/temp_repo

sed -i "s|image:.*|image: $2/$3:$4|g" k8s-specifications/$1-deployment.yaml

git add .

git config user.name "Azure Pipelines"
git config user.email "azure-pipelines@local"

git commit -m "Update Kubernetes manifest"

git push

rm -rf /tmp/temp_repo