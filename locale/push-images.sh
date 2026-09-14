#!/bin/bash
# Builda le 4 immagini dei servizi e le pubblica su Docker Hub
# I nodi del cluster le scaricano da soli a differenza del modo precedente
# Prerequisito: docker login
# Uso: ./push-images.sh   (dalla cartella locale/)
set -e

DOCKER_USER="${DOCKER_USER:-mavit2002}" #mio nome utente 
TAG="${TAG:-1.0}"
SERVICES="menu-service order-service kitchen-service frontend"

for s in $SERVICES; do
  echo "== build $DOCKER_USER/$s:$TAG =="
  docker build -t "$DOCKER_USER/$s:$TAG" ./$s
  echo "== push $DOCKER_USER/$s:$TAG =="
  docker push "$DOCKER_USER/$s:$TAG"
done

echo "Fatto. Immagini pubblicate su Docker Hub ($DOCKER_USER)."