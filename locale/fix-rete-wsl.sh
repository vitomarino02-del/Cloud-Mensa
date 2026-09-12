#!/bin/bash
# Ripristina l'accesso a internet delle VM Multipass quando si lavora da WSL.
#
# Le regole di NAT non sopravvivono al riavvio di WSL, e Docker imposta la
# policy della catena FORWARD a DROP: senza queste regole le VM risolvono i
# nomi (il DNS lo serve il gateway di Multipass) ma nessuno inoltra il loro
# traffico verso internet, e apt va in timeout.
#
# Uso: sudo bash fix-rete-wsl.sh
# Per renderlo automatico a ogni avvio di WSL, vedere il README.

BRIDGE="mpqemubr0"

if ! ip link show "$BRIDGE" > /dev/null 2>&1; then
  echo "Il bridge $BRIDGE non esiste: Multipass non e' avviato."
  echo "Lancia prima 'multipass start --all' e riprova."
  exit 1
fi

# ricava la subnet dal bridge invece di scriverla fissa: se Multipass la
# cambia, lo script continua a funzionare
SUBNET=$(ip -4 -o addr show "$BRIDGE" | awk '{print $4}')
echo "rete delle VM: $SUBNET"

sysctl -w net.ipv4.ip_forward=1 > /dev/null

# -C verifica se la regola esiste gia', per non accumulare duplicati
iptables -t nat -C POSTROUTING -s "$SUBNET" ! -o "$BRIDGE" -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s "$SUBNET" ! -o "$BRIDGE" -j MASQUERADE

iptables -C FORWARD -i "$BRIDGE" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD -i "$BRIDGE" -j ACCEPT

iptables -C FORWARD -o "$BRIDGE" -j ACCEPT 2>/dev/null \
  || iptables -I FORWARD -o "$BRIDGE" -j ACCEPT

echo "regole applicate."
