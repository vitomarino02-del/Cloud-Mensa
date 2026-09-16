# Cloud Mensa ---- VERSIONE LOCALE

Applicazione web per ordinare alla mensa universitaria, sviluppata come progetto per il corso
di Sistemi Cloud. Architettura 3-tier a microservizi, containerizzata con Docker e deployata
su un cluster Kubernetes locale (3 VM Multipass) gestito con Terraform e Ansible.

## Architettura

L'app è composta da tre microservizi Python/Flask, un frontend React e tre componenti di supporto:

- **menu-service**: catalogo dei piatti e upload delle foto. Lo storage delle immagini è
  astratto: con `STORAGE_BACKEND=local` salva su un volume, con `s3` userebbe un bucket
  Amazon S3 senza modifiche al codice.
- **order-service**: creazione degli ordini e avanzamento degli stati
  (ricevuto → in preparazione → pronto → ritirato). A ogni ordine: salva su Postgres,
  aggiorna il tabellone su Redis, pubblica un evento su RabbitMQ.
- **kitchen-service**: consumer senza API. Ascolta gli eventi ordine dalla coda e
  simula le notifiche alla cucina (log).
- **frontend**: SPA React servita da Nginx, che fa anche da gateway verso le API
  (`/api/menu` → menu-service, `/api/orders` → order-service).
- **PostgreSQL**: dato "di verità" (piatti, ordini, storico).
- **Redis**: tabellone cucina, solo gli ordini attivi già serializzati, per il polling
  frequente del display senza caricare Postgres.
- **RabbitMQ**: exchange fanout `order.events` per la comunicazione asincrona; nuovi
  consumer possono aggiungersi senza modificare chi pubblica.

Flusso di un ordine: frontend → order-service → (Postgres + Redis + RabbitMQ) →
kitchen-service consuma l'evento → il personale avanza lo stato dal display cucina.

## Struttura del repo

```
.gitea/workflows/        pipeline CI/CD per Gitea: infra.yml, deploy.yml, destroy.yml
setup-gitea-repo.sh      crea il repo su Gitea, abilita Actions e carica i secret
CICD-GITEA.md            guida completa alle pipeline
locale/
├── menu-service/        microservizio catalogo (app.py, Dockerfile, requirements.txt)
├── order-service/       microservizio ordini
├── kitchen-service/     consumer RabbitMQ
├── frontend/            SPA React + nginx.conf
├── docker-compose.yml   esecuzione rapida senza Kubernetes
├── main.tf              Terraform: 3 VM Ubuntu con Multipass (1 control-plane + 2 worker)
├── cloud-init.yaml.tftpl  primo avvio VM: utente + chiave SSH
├── inventory.tpl        template dell'inventory Ansible (compilato da Terraform con gli IP)
├── ansible/             site.yml: prerequisiti, kubeadm init, join dei worker, CNI Flannel
├── k8s/                 manifest: Deployment, Service, ConfigMap, NodePort 30080
├── push-images.sh       build delle immagini e push nel repository docker hub
├── demo-images/         foto segnaposto dei piatti (1.jpg ... 9.jpg)
└── upload-images.sh     carica le foto dei piatti tramite l'API del menu-service
```

## Esecuzione rapida (Docker Compose)
## Alternativa, non fa parte della demo principale
Prerequisito: Docker. Dalla cartella `locale/`:

```
docker compose up --build
```

App su http://localhost:8080 (scheda "Menu & Ordina" e scheda "Display Cucina").
Console RabbitMQ su http://localhost:15672 (guest/guest).

## Deployment sul cluster Kubernetes con la pipeline (Gitea)

La strada principale, come nel laboratorio *Kubernetes GitOps with Gitea*
([lab/k8s-gitea-cicd](https://github.com/unict-cloud-systems/lab-2026/tree/main/lab/k8s-gitea-cicd)),
è un push sul repo ospitato su Gitea. Il runner `act_runner` gira in WSL
(`runs-on: self-hosted`) ed esegue tre pipeline:

| Pipeline | Quando parte | Cosa fa |
|---|---|---|
| `infra.yml` | push su `main.tf`, template o `ansible/**` (o a mano) | Terraform crea le VM, Ansible monta il cluster, il kubeconfig viene salvato in `~/mensa-kubeconfig` |
| `deploy.yml` | push sui servizi o su `k8s/**` (o a mano) | build delle immagini, push su Docker Hub con tag = SHA del commit, `kubectl apply`, attesa del rollout, foto dei piatti |
| `destroy.yml` | solo a mano | `terraform destroy` e pulizia dei file sull'host |

Un cambio all'applicazione non ricrea il cluster, e un cambio all'infrastruttura non
rifà il deploy. Lo stato di Terraform (`~/mensa-terraform.tfstate`) e l'inventory
(`~/mensa-hosts.ini`) stanno nella home di WSL e non nel repo, perché il runner fa un
checkout nuovo a ogni job. Le chiavi SSH e le credenziali di Docker Hub arrivano dai
secret di Gitea.

### Come si avvia, passo passo

Tutti i comandi vanno nel **terminale WSL**. Servono tre terminali aperti:
uno per Gitea, uno per il runner, uno per lavorare. I dettagli e la tabella dei
problemi sono in [CICD-GITEA.md](CICD-GITEA.md).

#### A. Preparazione (una volta sola)

1. **Strumenti.** Devono esserci multipass, terraform, ansible, kubectl, docker, jq,
   git, **node 20+** (serve al runner per `actions/checkout`) e la chiave `~/.ssh/id_rsa`:
   ```bash
   for c in multipass terraform ansible-playbook kubectl docker jq git node; do
     printf '%-18s' "$c"; command -v $c >/dev/null && echo OK || echo MANCA
   done
   ```
2. **Gitea** (terminale 1):
   ```bash
   mkdir -p ~/gitea/data ~/gitea/conf && cd ~/gitea
   curl -L https://dl.gitea.com/gitea/1.26.0/gitea-1.26.0-linux-amd64 -o gitea && chmod +x gitea
   ./gitea web --config conf/app.ini --port 3000
   ```
   Su http://localhost:3000 completare l'installazione (database **SQLite3**) e creare
   l'utente amministratore.
3. **Runner** (terminale 2). Token da *Site Administration → Actions → Runners →
   Create new runner*:
   ```bash
   mkdir -p ~/act-runner && cd ~/act-runner
   curl -sSfL https://dl.gitea.com/act_runner/0.4.1/act_runner-0.4.1-linux-amd64 -o act_runner && chmod +x act_runner
   ./act_runner register --instance http://localhost:3000 --token <TOKEN-RUNNER> \
     --name host-runner --labels "self-hosted,linux,multipass" --no-interactive
   ./act_runner daemon
   ```
   Nella pagina Runners deve risultare **Idle**.
4. **Token**: uno di Gitea (*Settings → Applications*, permessi repository e user in
   lettura/scrittura) e uno di Docker Hub (*Account settings → Personal access tokens*).
5. **Repo e secret su Gitea** (terminale 3):
   ```bash
   cd /mnt/c/Users/vitom/Desktop/Cloud-Mensa
   GITEA_TOKEN=<token-gitea> DOCKERHUB_TOKEN=<token-dockerhub> bash setup-gitea-repo.sh
   git remote add gitea http://localhost:3000/<utente>/Cloud-Mensa.git
   ```
6. **Stato di Terraform nella home** (se esiste ancora quello vecchio):
   ```bash
   [ -f locale/terraform.tfstate ] && [ ! -f ~/mensa-terraform.tfstate ] && \
     mv locale/terraform.tfstate ~/mensa-terraform.tfstate
   ```

#### B. Avvio (ogni volta)

1. **Docker Desktop** acceso per primo.
2. **Terminale 1**: `cd ~/gitea && ./gitea web --config conf/app.ini --port 3000`
3. **Terminale 2**: `cd ~/act-runner && ./act_runner daemon`
4. **Terminale 3**, rete delle VM:
   ```bash
   cd /mnt/c/Users/vitom/Desktop/Cloud-Mensa
   sudo bash locale/fix-rete-wsl.sh
   ```
5. **Cluster**: la prima volta `git push gitea main`; le volte successive da Gitea
   *Cloud-Mensa → Actions → **Provision K8s Cluster** → Run workflow*.
   Circa 10-15 minuti: Terraform crea le VM, Ansible monta il cluster, il kubeconfig
   finisce in `~/mensa-kubeconfig`.
6. **Applicazione**: quando il cluster è verde, *Actions → **Deploy to Kubernetes** →
   Run workflow*. (Al primo push parte da solo ma fallisce perché il cluster non c'è
   ancora: va solo rilanciato.)
7. **Verifica**:
   ```bash
   KUBECONFIG=~/mensa-kubeconfig kubectl get nodes           # 3 nodi Ready
   KUBECONFIG=~/mensa-kubeconfig kubectl -n mensa get pods   # tutti Running
   KUBECONFIG=~/mensa-kubeconfig kubectl -n mensa get deploy -o wide   # tag = SHA del commit
   ```
8. **Browser di Windows**:
   ```bash
   KUBECONFIG=~/mensa-kubeconfig kubectl -n mensa port-forward svc/frontend 8081:80 --address 0.0.0.0
   ```
   e aprire http://localhost:8081.
9. **Aggiornare l'app**: modifica, `git commit`, `git push gitea main` → parte da solo
   *Deploy to Kubernetes*. Rollback: `git revert HEAD --no-edit && git push gitea main`.

#### C. Spegnimento

- Pausa: `multipass stop --all` (al riavvio il cluster riparte da solo).
- Distruzione: *Actions → **Destroy K8s Cluster** → Run workflow*.
- Gitea e runner: Ctrl+C nei rispettivi terminali.

#### Insieme alla versione AWS

Le due versioni possono girare contemporaneamente: repo, stato Terraform, registry e
cluster sono separati. Conviene avviare prima AWS (RDS è lento) e usare due comandi
distinti per non sbagliare cluster:
```bash
alias kloc='KUBECONFIG=~/mensa-kubeconfig kubectl'
alias kaws='KUBECONFIG=~/mensa-aws-kubeconfig kubectl'
```

## Deployment sul cluster Kubernetes a mano (piano B)

Prerequisiti: Multipass, Terraform, Ansible, kubectl, una chiave SSH in `~/.ssh/id_rsa`, account dockerHub con docker login gia eseguito.
Su Windows i comandi vanno lanciati da WSL2 (vedi note più sotto). Dalla cartella `locale/`:

```
bash up.sh
```

Lo script incatena i passaggi: crea le VM con Terraform, verifica che raggiungano
internet (vedi la nota sulla rete WSL più sotto), monta il cluster con Ansible, costruisce le immagini e le pubblica su Docker Hub (da cui i nodi le prelevano) e applica i manifest.. Per fermare tutto:
`bash down.sh`, oppure `multipass stop --all` se è solo una pausa, in quel caso al
riavvio il cluster riparte da solo.

`up.sh` usa lo stesso file di stato della pipeline, quindi le due strade si possono
alternare senza creare VM doppie. Questo file non fa altro che lanciare i seguenti comandi:

```
terraform init -backend-config="path=$HOME/mensa-terraform.tfstate"
terraform apply                        # crea le 3 VM e genera ansible/inventory.ini
cd ansible && ansible-playbook -i inventory.ini site.yml   # cluster kubeadm + Flannel
cd .. && bash push-images.sh           # build immagini e push nel registry docker hub
export KUBECONFIG=$PWD/ansible/kubeconfig
kubectl apply -f k8s/
kubectl -n mensa get pods              # attendere che siano tutti Running
```

App su `http://<IP di un worker>:30080` (Service NodePort). Se il browser non raggiunge
la rete delle VM (caso tipico con WSL): 
IMPORTANTE: lanciare dalla cartella Cloud-mensa/locale

`export KUBECONFIG=/mnt/c/Users/vitom/Desktop/Cloud-mensa/locale/ansible/kubeconfig`
`kubectl -n mensa port-forward svc/frontend 8081:80 --address 0.0.0.0`
 e aprire http://localhost:8081.
 Se si apre da browser.

Le foto dei piatti si caricano tramite l'API (`bash upload-images.sh` (già integrato in bash up.sh), default su
localhost:8081; passare l'URL base come argomento per il compose). Sul cluster le foto
stanno in un volume `emptyDir`: dopo un riavvio del pod menu-service vanno ricaricate
(con lo storage `s3` della Fase 2 sarebbero persistenti).

## Scelte progettuali

- **Postgres + Redis insieme**: Postgres è lo storico transazionale; Redis tiene solo gli
  ordini attivi, già in JSON, per letture rapide e frequenti. Se Redis non è disponibile
  l'app degrada (warning nei log) ma gli ordini continuano a salvarsi.
- **Exchange fanout**: il producer non conosce i consumer; si possono aggiungere altri
  servizi (statistiche, notifiche) senza toccare order-service.
- **Configurazione via variabili d'ambiente**: stesso codice in compose e nel cluster,
  cambia solo la ConfigMap; la stessa idea renderebbe possibile la migrazione cloud
  (RDS, ElastiCache, S3) senza modifiche applicative.
- **containerd sui nodi**: Kubernetes parla con il runtime tramite CRI; Docker serve solo
  sulla macchina di sviluppo per costruire le immagini.
- **Registro delle immagini**: le immagini dei quattro servizi sono pubblicate su Docker Hub (mavit2002/...) e scaricate autonomamente dai nodi, come già avviene per le immagini ufficiali di Postgres, Redis e RabbitMQ. È lo stesso modello della Fase 2, dove il registro è Amazon ECR e l'accesso richiede credenziali temporanee. Lo script load-images.sh resta come alternativa per ambienti senza connettività: esporta le immagini in archivi e le importa nel containerd di ciascun nodo, e in quel caso i manifest richiedono imagePullPolicy: Never.

## Problemi incontrati e soluzioni

- **Race condition sul primo avvio**: più worker gunicorn (e più servizi) eseguivano
  `db.create_all()` in parallelo sullo stesso DB vuoto e uno crashava. Risolto gestendo
  l'eccezione con rollback: chi perde la corsa prosegue.
- **In Kubernetes non esiste `depends_on`**: i pod partono in ordine casuale e i servizi
  possono trovarsi il DB non ancora pronto. Risolto con un ciclo di retry all'avvio
  (riprova su `OperationalError`, prosegue se le tabelle esistono già).
- **Schema condiviso tra servizi**: order-service definiva la tabella `dishes` in forma
  ridotta; se partiva per primo creava una tabella incompleta. Risolto dichiarando lo
  schema identico nei due servizi. Nota: la condivisione di tabelle tra microservizi è
  un compromesso; la forma pura prevede un database per servizio.
- **Windows Home senza Hyper-V**: Multipass non poteva creare VM con rete funzionante
  (VirtualBox NAT assegna lo stesso IP a tutte). Risolto spostando la parte infrastruttura
  in WSL2, che espone KVM: Multipass con driver qemu, Terraform e Ansible girano lì.
  Attenzione anche ad Ansible che ignora `ansible.cfg` nelle cartelle montate da Windows
  (world-writable): inventory passato con `-i`.

- **Le VM senza internet dopo un riavvio**: il playbook si piantava su "Installa
  containerd" perché `apt` non scaricava nulla. Negli errori si vedeva la differenza fra
  IPv6 ("Network is unreachable", normale) e IPv4 ("connection timed out"): i pacchetti
  uscivano e non tornava niente, mentre il DNS funzionava perché lo serve il gateway di
  Multipass. Le regole di NAT non sono persistenti e si perdono al riavvio di WSL, e
  Docker imposta la policy di FORWARD a DROP lasciando solo le proprie: le VM restavano
  senza nessuno che inoltrasse il traffico. Rimedio in `fix-rete-wsl.sh`, richiamato
  anche da `up.sh` quando il controllo di connettività fallisce. Per renderlo automatico
  a ogni avvio di WSL si può copiare lo script in `/usr/local/bin/` e aggiungere a
  `/etc/wsl.conf` una sezione `[boot]` con `command = /usr/local/bin/fix-rete-wsl.sh`.
- **Un handler Ansible che non veniva mai eseguito**: subito dopo, `kubeadm init`
  falliva sul controllo di `ip_forward`, benché il playbook lo impostasse. Gli handler
  girano a fine play: essendo il playbook fallito prima, l'handler non era partito; al
  rilancio il file esisteva già, quindi il task risultava `ok` e non `changed` — e un
  task non cambiato non notifica il proprio handler. Il file c'era, il valore non era
  mai stato caricato nel kernel. Risolto trasformando l'applicazione dei parametri
  sysctl in un task normale, eseguito a ogni run. Da notare che si tratta di due
  `ip_forward` distinti: uno in WSL, per far uscire le VM su internet, e uno dentro le
  VM, richiesto da Kubernetes per la rete dei pod.
