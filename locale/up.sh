#!/bin/bash
# Avvia tutto l'ambiente locale: VM, cluster Kubernetes, applicazione.
# Uso: bash up.sh
# Strada principale: le pipeline Gitea (.gitea/workflows). Questo script resta
# come piano B, per avviare tutto a mano se il runner non e' disponibile.
set -e

echo "== 1/6 macchine virtuali =="
# una tantum: sposta lo stato dalla vecchia posizione (cartella del repo) alla home
if [ -f terraform.tfstate ] && [ ! -f "$HOME/mensa-terraform.tfstate" ]; then
  mv -n terraform.tfstate "$HOME/mensa-terraform.tfstate"
fi
terraform init -input=false -reconfigure -backend-config="path=$HOME/mensa-terraform.tfstate"
terraform apply -auto-approve

echo
echo "== 2/6 verifica rete delle VM =="
# controllo prima di proseguire: senza internet i nodi non installerebbero
# i pacchetti durante il playbook, ne' scaricherebbero le immagini dal registro
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
echo "== 3/6 cluster Kubernetes =="
cd ansible
ansible-playbook -i inventory.ini site.yml
cd ..
export KUBECONFIG="$PWD/ansible/kubeconfig"
kubectl get nodes

echo
echo "== 4/6 pubblicazione delle immagini sul registro =="
# le immagini vengono costruite qui e pubblicate su Docker Hub;
# saranno i nodi a scaricarle quando lo scheduler vi assegna i pod
if ! grep -q "index.docker.io" "$HOME/.docker/config.json" 2>/dev/null; then
  echo "ERRORE: non risulti autenticato su Docker Hub."
  echo "Esegui prima:  docker login -u mavit2002"
  exit 1
fi
bash push-images.sh

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
echo "Dal browser di Windows devi fare il port-forward:"
echo "  export KUBECONFIG=$PWD/ansible/kubeconfig"
echo "  kubectl -n mensa port-forward svc/frontend 8081:80 --address 0.0.0.0"
echo "  poi apri http://localhost:8081 per usare l'app"