#!/bin/bash
# Avvia tutto l'ambiente locale: VM, cluster Kubernetes, applicazione.
# Uso: bash up.sh
set -e

echo "== 1/5 macchine virtuali =="
terraform init -input=false
terraform apply -auto-approve

echo
echo "== 2/5 verifica rete delle VM =="
# controllo prima di lanciare Ansible: se le VM non raggiungono internet
# l'installazione dei pacchetti fallirebbe a meta' playbook
if ! multipass exec mensa-cp -- ping -c1 -W3 8.8.8.8 > /dev/null 2>&1; then
  echo "le VM non escono su internet, applico le regole di rete"
  sudo bash fix-rete-wsl.sh
  sleep 3
  if ! multipass exec mensa-cp -- ping -c1 -W3 8.8.8.8 > /dev/null 2>&1; then
    echo "ERRORE: le VM continuano a non raggiungere internet."
    echo "Controlla 'multipass list' e la connessione del PC."
    exit 1
  fi
fi
echo "rete ok"

echo
echo "== 3/5 cluster Kubernetes =="
cd ansible
ansible-playbook -i inventory.ini site.yml
cd ..
export KUBECONFIG="$PWD/ansible/kubeconfig"
kubectl get nodes

echo
echo "== 4/5 immagini nei nodi =="
# senza registry le immagini vanno costruite e importate in ogni worker
bash load-images.sh

echo
echo "== 5/6 deploy dell'applicazione =="
kubectl apply -f k8s/
kubectl -n mensa wait --for=condition=available --timeout=300s deployment --all
kubectl -n mensa get pods

echo
echo "== 6/6 foto dei piatti =="
# da WSL i worker sono raggiungibili direttamente sulla NodePort
APP=$(terraform output -raw frontend_url)
bash upload-images.sh "$APP"

echo
echo "App raggiungibile su: $APP"
echo
echo "Dal browser di Windows conviene invece il port-forward:"
echo "  export KUBECONFIG=$PWD/ansible/kubeconfig"
echo "  kubectl -n mensa port-forward svc/frontend 8081:80 --address 0.0.0.0"
echo "  poi apri http://localhost:8081"
