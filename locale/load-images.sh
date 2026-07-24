#!/bin/bash
# Builda le 4 immagini e le carica nei nodi del cluster (niente registry in locale).
# Uso: ./load-images.sh   (dalla cartella locale/)
set -e

SERVICES="menu-service order-service kitchen-service frontend"
NODES="mensa-worker-1 mensa-worker-2"

# nota: multipass (snap) non puo' leggere /tmp, quindi i tar vanno nella home
TMPDIR="$HOME/mensa-images"
mkdir -p "$TMPDIR"

for s in $SERVICES; do
  echo "== build $s =="
  docker build -t mensa/$s:1.0 ./$s
  docker save mensa/$s:1.0 -o "$TMPDIR/$s.tar"
  for vm in $NODES; do
    echo "== carico $s su $vm =="
    multipass transfer "$TMPDIR/$s.tar" $vm:/tmp/$s.tar
    # importa nel containerd del nodo, nel namespace usato da Kubernetes
    multipass exec $vm -- sudo ctr -n k8s.io images import /tmp/$s.tar
    multipass exec $vm -- rm /tmp/$s.tar
  done
  rm "$TMPDIR/$s.tar"
done

echo "Fatto. Immagini presenti sui nodi:"
multipass exec mensa-worker-1 -- sudo ctr -n k8s.io images ls -q | grep mensa
