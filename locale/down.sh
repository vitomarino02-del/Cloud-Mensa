#!/bin/bash
# Distrugge le VM e libera le risorse del PC.
# Per una pausa breve conviene invece 'multipass stop --all', che le spegne
# senza cancellarle: al riavvio il cluster riparte da solo.
# Uso: bash down.sh
set -e

# una tantum: sposta lo stato dalla vecchia posizione (cartella del repo) alla home
if [ -f terraform.tfstate ] && [ ! -f "$HOME/mensa-terraform.tfstate" ]; then
  mv -n terraform.tfstate "$HOME/mensa-terraform.tfstate"
fi
terraform init -input=false -reconfigure -backend-config="path=$HOME/mensa-terraform.tfstate"
terraform destroy -auto-approve
multipass list
