#!/bin/bash
set -uex
set -o pipefail

LOCATION="eu-central-h1"
PREFIX="mastodon-demo"

# 1. Destroy VMs
for svc in web-vm streaming-vm sidekiq-vm valkey-vm; do
  echo "Destroying VM: ${svc}"
  ubi vm "${LOCATION}/${PREFIX}-${svc}" destroy -f || true
done

# 2. Destroy load balancers
for lb in web streaming; do
  echo "Destroying load balancer: ${lb}"
  ubi lb "${LOCATION}/${PREFIX}-${lb}" destroy -f || true
done

# 3. Destroy custom firewalls
for fw in ssh-internet-fw https-internet-fw valkey-fw pg-fw; do
  echo "Destroying firewall: ${fw}"
  ubi fw "${LOCATION}/${PREFIX}-${fw}" destroy -f || true
done

# 4. Destroy PostgreSQL
echo "Destroying PostgreSQL..."
ubi pg "${LOCATION}/${PREFIX}-pg" destroy -f || true

# 5. Destroy subnets
for ps in web-subnet streaming-subnet sidekiq-subnet valkey-subnet pg-subnet; do
  echo "Destroying subnet: ${ps}"
  ubi ps "${LOCATION}/${PREFIX}-${ps}" destroy -f || true
done

echo "=========================================="
echo "All resources destroyed."
echo "=========================================="
