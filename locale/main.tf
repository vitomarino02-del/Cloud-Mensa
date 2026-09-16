# Fase 1 - Infrastruttura locale: 3 VM Ubuntu create con Multipass.
# 1 control-plane + 2 worker per il cluster Kubernetes (kubeadm via Ansible).
# Uso:  terraform init && terraform apply

terraform {
  required_version = ">= 1.6"
  required_providers {
    multipass = {
      source  = "larstobi/multipass"
      version = "~> 1.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # Stato locale, ma FUORI dalla cartella del repo: la pipeline Gitea fa un
  # checkout nuovo a ogni job, quindi lo stato deve stare in un posto fisso
  # dell'host. Il percorso si passa a init:
  #   terraform init -backend-config="path=$HOME/mensa-terraform.tfstate"
  backend "local" {}
}

provider "multipass" {}

variable "worker_count" {
  description = "Numero di nodi worker"
  type        = number
  default     = 2
}

# kubeadm richiede almeno 2 CPU e 2GB di RAM per nodo
variable "cpus" {
  type    = number
  default = 2
}

variable "memory" {
  type    = string
  default = "2G"
}

variable "disk" {
  type    = string
  default = "10G"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_rsa.pub"
}

variable "ssh_private_key_path" {
  type    = string
  default = "~/.ssh/id_rsa"
}

# Dove scrivere l'inventory Ansible. Vuoto = ansible/inventory.ini (uso da up.sh);
# la pipeline lo mette nella home dell'host (~/mensa-hosts.ini) per condividerlo tra i job.
variable "inventory_path" {
  type    = string
  default = ""
}

locals {
  inventory_file = var.inventory_path != "" ? pathexpand(var.inventory_path) : "${path.module}/ansible/inventory.ini"
}

# cloud-init: primo avvio delle VM (utente + chiave SSH per Ansible + docker)
resource "local_file" "cloudinit" {
  filename = "${path.module}/.cloud-init.generated.yaml"
  content = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
}

# ---- Control plane ----
resource "multipass_instance" "control_plane" {
  name           = "mensa-cp"
  image          = "22.04"
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloudinit.filename
}

# ---- Workers ----
resource "multipass_instance" "worker" {
  count          = var.worker_count
  name           = "mensa-worker-${count.index + 1}"
  image          = "22.04"
  cpus           = var.cpus
  memory         = var.memory
  disk           = var.disk
  cloudinit_file = local_file.cloudinit.filename
}

# Inventory per Ansible generato con gli IP reali delle VM
resource "local_file" "ansible_inventory" {
  filename = local.inventory_file
  content = templatefile("${path.module}/inventory.tpl", {
    cp_ip        = multipass_instance.control_plane.ipv4
    worker_ips   = [for w in multipass_instance.worker : w.ipv4]
    ssh_key_path = pathexpand(var.ssh_private_key_path)
  })
}

output "control_plane_ip" {
  value = multipass_instance.control_plane.ipv4
}

output "worker_ips" {
  value = [for w in multipass_instance.worker : w.ipv4]
}

output "frontend_url" {
  description = "URL dell'app dopo il deploy su K8s (NodePort 30080)"
  value       = "http://${multipass_instance.worker[0].ipv4}:30080"
}
