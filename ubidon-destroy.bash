#!/bin/bash
set -uex
set -o pipefail

LOCATION="eu-central-h1"
PREFIX="mastodon-demo"

# 1. Destroy VMs
for svc in web-vm streaming-vm sidekiq-vm valkey-vm; do
  if ubi vm "${LOCATION}/${PREFIX}-${svc}" show &>/dev/null; then
    echo "Destroying VM: ${svc}"
    ubi vm "${LOCATION}/${PREFIX}-${svc}" destroy -f || true
  fi
done

# 2. Destroy load balancers
for lb in web streaming; do
  if ubi lb "${LOCATION}/${PREFIX}-${lb}" show &>/dev/null; then
    echo "Destroying load balancer: ${lb}"
    ubi lb "${LOCATION}/${PREFIX}-${lb}" destroy -f || true
  fi
done

# 3. Destroy PostgreSQL and its firewall
if ubi pg "${LOCATION}/${PREFIX}-pg" show &>/dev/null; then
  PG_ID=$(ubi pg "${LOCATION}/${PREFIX}-pg" show -f id | grep "id:" | sed 's/id: //' || true)
  echo "PostgreSQL ID: $PG_ID"
  
  if [ -n "$PG_ID" ]; then
    if ubi fw "${LOCATION}/${PG_ID}-firewall" show &>/dev/null; then
      echo "Destroying PostgreSQL firewall: ${PG_ID}-firewall"
      ubi fw "${LOCATION}/${PG_ID}-firewall" destroy -f || true
    fi
  fi
  
  echo "Destroying PostgreSQL..."
  ubi pg "${LOCATION}/${PREFIX}-pg" destroy -f || true
fi

# 4. Destroy custom firewalls
for fw in ssh-internet-fw https-internet-fw valkey-fw pg-fw; do
  if ubi fw "${LOCATION}/${PREFIX}-${fw}" show &>/dev/null; then
    echo "Destroying firewall: ${fw}"
    ubi fw "${LOCATION}/${PREFIX}-${fw}" destroy -f || true
  fi
done

# 5. Destroy subnets
for ps in web-subnet streaming-subnet sidekiq-subnet valkey-subnet; do
  if ubi ps "${LOCATION}/${PREFIX}-${ps}" show &>/dev/null; then
    echo "Destroying subnet: ${ps}"
    ubi ps "${LOCATION}/${PREFIX}-${ps}" destroy -f || true
  fi
done

echo "=========================================="
echo "All resources destroyed."
echo "=========================================="
