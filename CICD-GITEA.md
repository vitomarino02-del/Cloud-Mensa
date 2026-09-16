# Pipeline CI/CD locale con Gitea

Ricalca [lab/k8s-gitea-cicd](https://github.com/unict-cloud-systems/lab-2026/tree/main/lab/k8s-gitea-cicd)
del laboratorio (*Kubernetes GitOps with Gitea*): il repo contiene
sia l'infrastruttura (`locale/main.tf`, `locale/ansible/`) sia l'applicazione
(`locale/k8s/`, i servizi). Tre pipeline in `.gitea/workflows/`:

| File | Quando parte | Cosa fa |
|---|---|---|
| `infra.yml` | push su `main.tf`, `cloud-init`, `inventory.tpl`, `ansible/**` (o a mano) | `terraform apply` → playbook Ansible → salva `~/mensa-kubeconfig` |
| `deploy.yml` | push sui servizi o su `k8s/**` (o a mano) | build e push su Docker Hub (tag = SHA) → `kubectl apply` → rollout → foto |
| `destroy.yml` | **solo a mano** | `terraform destroy` e pulizia dei file sull'host |

Un cambio all'app non ricrea il cluster; un cambio all'infrastruttura non rifà il deploy.

## File che restano sull'host (fuori dal repo)

| File | Scritto da | Usato da |
|---|---|---|
| `~/mensa-terraform.tfstate` | `terraform apply` | tutte le esecuzioni di Terraform |
| `~/mensa-hosts.ini` | Terraform (`local_file`) | Ansible |
| `~/mensa-kubeconfig` | job `configure` di `infra.yml` | `deploy.yml` |

Le chiavi SSH vengono scritte a ogni job dai secret in `locale/id_rsa(.pub)`
(ignorate da git), come `terraform/id_ed25519` nel laboratorio.

Differenze rispetto al laboratorio: Terraform invece di OpenTofu; un solo playbook
`site.yml`; `deploy.yml` costruisce e pubblica le immagini su Docker Hub (il lab usa
nginx); un controllo della rete delle VM prima di Ansible (problema di Docker in WSL).

## Preparazione (una volta sola, da WSL)

1. Avvia Gitea e registra `act_runner` come nel laboratorio
   (`./install-gitea.sh`, poi `GITEA_TOKEN=<token> ./register-runner.sh`,
   etichette `self-hosted,linux,multipass`) e lascia acceso `./act_runner daemon`.
   Il runner deve girare **in WSL**, con lo stesso utente che usa Multipass, Terraform,
   Ansible, kubectl e Docker.
2. Crea il repo su Gitea, abilita Actions e carica i 4 secret
   (`SSH_PRIVATE_KEY`, `SSH_PUBLIC_KEY`, `DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`)
   con lo script adattato da `setup-repo.sh` del laboratorio:
   ```bash
   GITEA_TOKEN=<token-gitea> DOCKERHUB_TOKEN=<token-dockerhub> ./setup-gitea-repo.sh
   ```
   Le chiavi usate sono `~/.ssh/id_rsa(.pub)`, le stesse gia' nelle VM.
   Il token Docker Hub si crea da Account settings → Personal access tokens.
3. Aggiungi Gitea come secondo remote e fai il push:
   ```bash
   git remote add gitea http://localhost:3000/<utente>/Cloud-Mensa.git
   git push gitea main
   ```
   Il repo resta anche su GitHub (`origin`): la pipeline gira solo su Gitea.
   Al primo push puo' partire anche `deploy.yml` e fallire perche' il cluster non
   c'e' ancora: finito `infra.yml`, rilancialo da Actions → Run workflow.

## Uso durante la demo

```bash
# 0. rete delle VM (dopo ogni riavvio di WSL o Docker)
sudo bash locale/fix-rete-wsl.sh

# 1. cluster: Gitea → Actions → "Provision cluster locale" → Run workflow
#    (oppure parte da solo con un push su main.tf / ansible)

# 2. modifica visibile all'app, poi push → parte "Deploy applicazione locale"
git commit -am "feat: nuova etichetta nel frontend" && git push gitea main

# 3. verifica: il tag delle immagini e' lo SHA del commit
export KUBECONFIG=~/mensa-kubeconfig
kubectl -n mensa get deploy -o wide

# rollback = un altro commit
git revert HEAD --no-edit && git push gitea main

# 4. fine: Gitea → Actions → "Destroy cluster locale" → Run workflow
```

## Piano B

`bash locale/up.sh` e `bash locale/down.sh` fanno le stesse cose a mano e usano lo
stesso file di stato (`~/mensa-terraform.tfstate`), quindi si possono alternare
con le pipeline senza creare VM doppie.
