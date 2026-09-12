#!/bin/bash
# Distrugge le VM e libera le risorse del PC.
# Per una pausa breve conviene invece 'multipass stop --all', che le spegne
# senza cancellarle: al riavvio il cluster riparte da solo.
# Uso: bash down.sh
set -e

terraform destroy -auto-approve
multipass list
