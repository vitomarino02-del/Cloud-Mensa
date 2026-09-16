#!/usr/bin/env bash
# setup-gitea-repo.sh - crea il repo su Gitea, abilita Actions e carica i secret.
# Adattato da lab/k8s-gitea-cicd/setup-repo.sh del laboratorio.
#
# Prerequisiti:
#   - Gitea su http://localhost:3000   (lab/gitea-setup/install-gitea.sh)
#   - act_runner registrato con etichette self-hosted,linux,multipass
#     (lab/gitea-setup/register-runner.sh) e avviato: ./act_runner daemon
#   - chiavi SSH del PC in ~/.ssh/id_rsa e ~/.ssh/id_rsa.pub
#     (le stesse gia' installate nelle VM)
#   - un access token di Docker Hub
#
# Uso (da WSL, nella cartella del repo):
#   GITEA_TOKEN=<token-gitea> DOCKERHUB_TOKEN=<token-dockerhub> ./setup-gitea-repo.sh
#
# Token Gitea: avatar -> Settings -> Applications (scope repository e user, read/write)

set -euo pipefail

GITEA_URL="http://localhost:3000"
REPO_NAME="Cloud-Mensa"
DOCKERHUB_USERNAME="${DOCKERHUB_USERNAME:-mavit2002}"
SSH_PRIVATE_KEY_FILE="${SSH_PRIVATE_KEY_FILE:-$HOME/.ssh/id_rsa}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

for v in GITEA_TOKEN DOCKERHUB_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERRORE: variabile $v non impostata."
    exit 1
  fi
done

for f in "$SSH_PRIVATE_KEY_FILE" "$SSH_PUBLIC_KEY_FILE"; do
  [[ -f "$f" ]] || { echo "ERRORE: chiave $f non trovata."; exit 1; }
done

command -v jq &>/dev/null || { echo "ERRORE: serve jq (sudo apt install jq)"; exit 1; }

API="${GITEA_URL}/api/v1"
AUTH=(-H "Authorization: token ${GITEA_TOKEN}" -H "Content-Type: application/json")

# ── 1. Verifica del token ──────────────────────────────────────────────────
echo "==> Controllo l'API di Gitea..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH[@]}" "${API}/user")
if [[ "$HTTP" != "200" ]]; then
  echo "ERRORE: Gitea non risponde (HTTP ${HTTP}). E' avviato?"
  exit 1
fi
GITEA_USER=$(curl -s "${AUTH[@]}" "${API}/user" | jq -r '.login')
echo "    Autenticato come: ${GITEA_USER}"

# ── 2. Creazione del repository ────────────────────────────────────────────
echo "==> Creo il repository '${REPO_NAME}'..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${AUTH[@]}" \
  -X POST "${API}/user/repos" \
  -d "{\"name\":\"${REPO_NAME}\",\"private\":false,\"auto_init\":false}")
case "$HTTP" in
  201) echo "    Creato: ${GITEA_URL}/${GITEA_USER}/${REPO_NAME}" ;;
  409) echo "    Esiste gia', proseguo." ;;
  *)   echo "ERRORE: HTTP ${HTTP} nella creazione del repository."; exit 1 ;;
esac

# ── 3. Abilita Actions ─────────────────────────────────────────────────────
echo "==> Abilito Actions..."
curl -sSf "${AUTH[@]}" -X PATCH "${API}/repos/${GITEA_USER}/${REPO_NAME}" \
  -d '{"has_actions":true}' > /dev/null

# ── 4. Secret ──────────────────────────────────────────────────────────────
set_secret() {
  echo "==> Secret $1..."
  curl -sSf "${AUTH[@]}" \
    -X PUT "${API}/repos/${GITEA_USER}/${REPO_NAME}/actions/secrets/$1" \
    -d "{\"data\":$2}" > /dev/null
}
set_secret SSH_PRIVATE_KEY    "$(jq -Rs . < "$SSH_PRIVATE_KEY_FILE")"
set_secret SSH_PUBLIC_KEY     "$(jq -Rs . < "$SSH_PUBLIC_KEY_FILE")"
set_secret DOCKERHUB_USERNAME "$(printf '%s' "$DOCKERHUB_USERNAME" | jq -Rs .)"
set_secret DOCKERHUB_TOKEN    "$(printf '%s' "$DOCKERHUB_TOKEN" | jq -Rs .)"

# ── 5. Prossimi passi ──────────────────────────────────────────────────────
cat <<EOT

==> Fatto.

Aggiungi Gitea come secondo remote e fai il push (GitHub resta 'origin'):

  git remote add gitea ${GITEA_URL}/${GITEA_USER}/${REPO_NAME}.git
  git push gitea main

Pipeline:  ${GITEA_URL}/${GITEA_USER}/${REPO_NAME}/actions

Dopo "Provision K8s Cluster":
  KUBECONFIG=~/mensa-kubeconfig kubectl get nodes
EOT
