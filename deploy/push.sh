#!/bin/sh
# Builds the refinery image (deploy/Dockerfile) for arm64 and pushes it to the
# stack's repository, as <tag> (default dev). Run from Refinery's root, with
# AWS credentials for the stack's account:
#
#     deploy/push.sh [<tag>]
set -eu
tag=${1:-dev}
region=${AWS_REGION:-us-east-2}
account=$(aws sts get-caller-identity --query Account --output text)
registry=$account.dkr.ecr.$region.amazonaws.com
docker build --platform linux/arm64 -f deploy/Dockerfile -t "refinery:$tag" .
aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$registry"
docker tag "refinery:$tag" "$registry/refinery:$tag"
docker push "$registry/refinery:$tag"
