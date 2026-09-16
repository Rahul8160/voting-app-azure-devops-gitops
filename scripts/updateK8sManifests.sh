#!/bin/bash

set -x

# Set the repository URL
REPO_URL="https://6z1at9YLOrwZYfuYfCCmsEIVYhcSuaqBCOsCktEnjk3OuJVonnH8JQQJ99CIACAAAAAAAAAAAAASAZDO4TBc@dev.azure.com/rahulraval/voting-app/_git/voting-app"

# Clone the git repository into the /tmp directory
git clone "$REPO_URL" /tmp/temp_repo

# Navigate into the cloned repository directory
cd /tmp/temp_repo

# Make changes to the Kubernetes manifest file(s)
# For example, let's say you want to change the image tag in a deployment.yaml file
sed -i "s|image:.*|image: $2/$3:$4|g" k8s-specifications/$1-deployment.yaml

git add .

git config user.name "Azure Pipelines"
git config user.email "azure-pipelines@local"

git commit -m "Update Kubernetes manifest"

git push

# Cleanup: remove the temporary directory
rm -rf /tmp/temp_repo