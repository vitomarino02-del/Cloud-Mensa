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
├── load-images.sh       build delle immagini e caricamento nel containerd dei nodi
├── demo-images/         foto segnaposto dei piatti (1.jpg ... 9.jpg)
└── upload-images.sh     carica le foto dei piatti tramite l'API del menu-service
```

## Esecuzione rapida (Docker Compose)

Prerequisito: Docker. Dalla cartella `locale/`:

```
docker compose up --build
```

App su http://localhost:8080 (scheda "Menu & Ordina" e scheda "Display Cucina").
Console RabbitMQ su http://localhost:15672 (guest/guest).

## Deployment sul cluster Kubernetes

Prerequisiti: Multipass, Terraform, Ansible, kubectl, una chiave SSH in `~/.ssh/id_rsa`.
Su Windows i comandi vanno lanciati da WSL2 (vedi note più sotto). Dalla cartella `locale/`:

```
terraform init && terraform apply      # crea le 3 VM e genera ansible/inventory.ini
cd ansible && ansible-playbook -i inventory.ini site.yml   # cluster kubeadm + Flannel
cd .. && bash load-images.sh           # build immagini e import nei nodi (niente registry)
export KUBECONFIG=$PWD/ansible/kubeconfig
kubectl apply -f k8s/
kubectl -n mensa get pods              # attendere che siano tutti Running
```

App su `http://<IP di un worker>:30080` (Service NodePort). Se il browser non raggiunge
la rete delle VM (caso tipico con WSL): `kubectl -n mensa port-forward svc/frontend 8081:80
--address 0.0.0.0` e aprire http://localhost:8081.

Le foto dei piatti si caricano tramite l'API (`bash upload-images.sh`, default su
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
- **imagePullPolicy: Never + load-images.sh**: in locale non c'è un registry, le immagini
  vengono importate direttamente nel containerd dei nodi.

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
- **Snap e /tmp**: Multipass installato via snap non legge `/tmp`, i tar delle immagini
  passano dalla home.
