#!/usr/bin/env bash
# Vérifie la vraie table nftables dans un réseau entièrement jetable : aucune
# interface ni règle du PC n'est touchée. À lancer vous-même, ainsi :
#
#   sudo unshare --net bash tools/wansview-hotspot/tests/isolation-netns.sh
#
# Le script refuse de démarrer hors d'un espace de noms réseau neuf.
#
# Topologie (cet espace de noms joue le rôle du PC) :
#   camera --wifi0--+                      +--eth0-- lan, internet simulé
#                   |          PC          +--tailscale0, docker0, virbr0
# shellcheck disable=SC2319  # « [[ ... ]]; verdict $? » est voulu

set -uo pipefail
export LC_ALL=C

refuser() {
    echo "Refus : $*" >&2
    echo "Lancez : sudo unshare --net bash ${BASH_SOURCE[0]}" >&2
    exit 4
}

# ------------------------------------- garde-fous, avant toute modification
[[ $EUID -eq 0 ]] || refuser "droits root requis."
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ici_ns=$(readlink /proc/self/ns/net) || refuser "espace de noms illisible."
hote_ns=$(readlink /proc/1/ns/net) || refuser "espace de noms du système illisible."
[[ -n $ici_ns && -n $hote_ns && $ici_ns != "$hote_ns" ]] ||
    refuser "vous êtes dans l'espace de noms réseau du système."
interfaces=$(ip -o link show) || refuser "interfaces illisibles."
[[ $(grep -c . <<<"$interfaces") -eq 1 && $interfaces == *" lo: "* ]] ||
    refuser "cet espace de noms contient déjà des interfaces."

RACINE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
SERVEURS="$RACINE/tests/netns/serveurs.py"
ONVIF="$RACINE/outils/decouverte-onvif.py"
GARDE="$RACINE/wansview-garde.sh"
# shellcheck source=lib/commun.sh
source "$RACINE/lib/commun.sh" || exit 1
# shellcheck source=lib/regles.sh
source "$RACINE/lib/regles.sh" || exit 1
wh_configurer

for commande in ip nft nsenter unshare python3 sha256sum; do
    command -v "$commande" >/dev/null || { echo "Commande absente : $commande" >&2; exit 3; }
done

TRAVAIL=$(mktemp -d) || exit 1
PROCESSUS=()
declare -A PAIR=()
reussis=0
echoues=0

nettoyer() {
    local pid
    for pid in "${PROCESSUS[@]}"; do kill "$pid" 2>/dev/null; done
    rm -rf "$TRAVAIL"
}
trap nettoyer EXIT
trap 'exit 130' INT TERM HUP

fatal() {
    echo "Erreur de préparation : $*" >&2
    exit 1
}

# ------------------------------------------------------------------ topologie

# creer_pair <nom> <interface côté PC> <adresse PC/préfixe> <adresse pair/préfixe>
creer_pair() {
    local nom=$1 iface=$2 pid i
    unshare --net sleep 600 &
    pid=$!
    PROCESSUS+=("$pid")
    for ((i = 0; i < 100; i++)); do
        [[ $(readlink "/proc/$pid/ns/net") != "$ici_ns" ]] && break
        sleep 0.05
    done
    [[ $(readlink "/proc/$pid/ns/net") != "$ici_ns" ]] || fatal "espace de noms $nom"
    PAIR[$nom]=$pid
    ip link add "$iface" type veth peer name "p-$iface" netns "$pid" || fatal "lien $iface"
    { ip addr add "$3" dev "$iface" && ip link set "$iface" up; } || fatal "adresse $iface"
    {
        dans "$nom" ip link set lo up &&
            dans "$nom" ip addr add "$4" dev "p-$iface" &&
            dans "$nom" ip link set "p-$iface" up &&
            dans "$nom" ip route add default via "${3%/*}"
    } || fatal "configuration de $nom"
}

dans() { # <pair> <commande...>
    local pid=${PAIR[$1]}
    shift
    nsenter -t "$pid" -n -- "$@"
}

# serveur <pair ou pc> <options de serveurs.py...>
serveur() {
    local ou=$1 journal pid i
    shift
    journal="$TRAVAIL/serveur-$ou"
    if [[ $ou == pc ]]; then
        python3 -B "$SERVEURS" serveur "$@" >"$journal" 2>/dev/null &
    else
        nsenter -t "${PAIR[$ou]}" -n -- python3 -B "$SERVEURS" serveur "$@" >"$journal" 2>/dev/null &
    fi
    pid=$!
    PROCESSUS+=("$pid")
    for ((i = 0; i < 100; i++)); do
        grep -q PRET "$journal" 2>/dev/null && return 0
        sleep 0.05
    done
    fatal "serveur $ou"
}

ip link set lo up || fatal "boucle locale"
echo 1 >/proc/sys/net/ipv4/ip_forward || fatal "transfert IPv4 (dans cet espace seulement)"

creer_pair camera wifi0 "$WH_IP_AP/24" 10.42.0.10/24
creer_pair lan eth0 192.168.50.2/24 192.168.50.1/24
creer_pair tailscale tailscale0 100.100.0.1/24 100.100.0.2/24
creer_pair docker docker0 172.17.0.1/16 172.17.0.2/16
creer_pair libvirt virbr0 192.168.122.1/24 192.168.122.2/24

# Second réseau de l'Ethernet, à adresses publiques, et « Internet ».
{
    ip addr add 12.0.0.2/24 dev eth0 &&
        dans lan ip addr add 12.0.0.1/24 dev p-eth0 &&
        dans lan ip addr add 11.11.11.11/32 dev lo &&
        ip route add default via 192.168.50.1
} || fatal "Internet simulé"
# IPv6 sur le lien Wi-Fi pour vérifier qu'il est refusé en entrée.
{
    ip addr add fd42::1/64 dev wifi0 nodad &&
        dans camera ip addr add fd42::10/64 dev p-wifi0 nodad
} || fatal "IPv6"

serveur pc --tcp 0.0.0.0:22 --tcp 0.0.0.0:111 --tcp "$WH_IP_AP:8080" --tcp "$WH_IP_AP:53" \
    --tcp "[fd42::1]:22" --udp "$WH_IP_AP:53" --udp "$WH_IP_AP:67" --udp "$WH_IP_AP:5000"
# « --wsd » répond sur le port 3702, en multicast comme en unicast.
serveur camera --tcp 10.42.0.10:554 --tcp 10.42.0.10:80 --tcp 10.42.0.10:443 --wsd 10.42.0.10
serveur lan --tcp 192.168.50.1:8000 --tcp 12.0.0.1:8000 --tcp 11.11.11.11:80
serveur tailscale --tcp 100.100.0.2:80
serveur docker --tcp 172.17.0.2:80
serveur libvirt --tcp 192.168.122.2:80

# Règles préexistantes factices, dont la traduction d'adresses qui simule NAT.
nft -f - <<'REGLES' || fatal "règles préexistantes"
table inet preexistante {
	chain transfert {
		type filter hook forward priority filter; policy accept;
		counter
	}
}
table ip nat_simule {
	chain apres_routage {
		type nat hook postrouting priority srcnat; policy accept;
		ip saddr 10.42.0.0/24 oifname "eth0" masquerade
	}
}
REGLES
autres_regles() {
    nft -s list table inet preexistante && nft -s list table ip nat_simule
}
reference_autres=$(autres_regles) || fatal "lecture des règles préexistantes"

# ------------------------------------------------------------------- contrôles

verdict() { # <attendu 0|1> <obtenu> <description>
    local obtenu=$2
    ((obtenu != 0)) && obtenu=1
    if ((obtenu == $1)); then
        reussis=$((reussis + 1))
        echo "  OK     $3"
    else
        echoues=$((echoues + 1))
        echo "  ÉCHEC  $3"
    fi
}

joint() { # <description> <pair ou pc> <tcp|udp> <hôte> <port> [options]
    local texte=$1 ou=$2
    shift 2
    if [[ $ou == pc ]]; then
        python3 -B "$SERVEURS" "$@"
    else
        dans "$ou" python3 -B "$SERVEURS" "$@"
    fi
    verdict "$ATTENDU" $? "$texte"
}

passe() { ATTENDU=0 joint "$@"; }
bloque() { ATTENDU=1 joint "$@"; }

# Les destinations interdites aux clients, d'abord joignables puis bloquées.
destinations_interdites() { # <passe|bloque>
    "$1" "caméra → SSH du PC (Wi-Fi)" camera tcp "$WH_IP_AP" 22
    "$1" "caméra → SSH du PC (adresse Ethernet)" camera tcp 192.168.50.2 22
    "$1" "caméra → RPC du PC" camera tcp "$WH_IP_AP" 111
    "$1" "caméra → autre service du PC" camera tcp "$WH_IP_AP" 8080
    "$1" "caméra → UDP quelconque du PC" camera udp "$WH_IP_AP" 5000
    "$1" "caméra → SSH du PC en IPv6" camera tcp fd42::1 22
    "$1" "caméra → machine du réseau local" camera tcp 192.168.50.1 8000
    "$1" "caméra → réseau public de l'Ethernet" camera tcp 12.0.0.1 8000
    "$1" "caméra → Tailscale" camera tcp 100.100.0.2 80
    "$1" "caméra → Docker" camera tcp 172.17.0.2 80
    "$1" "caméra → libvirt" camera tcp 192.168.122.2 80
    "$1" "réseau local → caméra (nouvelle connexion)" lan tcp 10.42.0.10 554
}

trafic_autorise() {
    passe "caméra → DNS en UDP" camera udp "$WH_IP_AP" 53
    passe "caméra → DNS en TCP" camera tcp "$WH_IP_AP" 53
    passe "caméra → DHCP" camera udp "$WH_IP_AP" 67 --port-source 68
    passe "caméra → Internet" camera tcp 11.11.11.11 80
    passe "PC → caméra, RTSP (554)" pc tcp 10.42.0.10 554
    passe "PC → caméra, HTTP et ONVIF (80)" pc tcp 10.42.0.10 80
    passe "PC → caméra, HTTPS (443)" pc tcp 10.42.0.10 443
    passe "PC → caméra, UDP unicast (3702)" pc udp 10.42.0.10 3702
}

decouverte() { # <description>
    local sortie
    sortie=$(python3 -B "$ONVIF" --source "$WH_IP_AP" --duree 2 2>&1)
    [[ $sortie == *"http://10.42.0.10/onvif/device_service"* ]]
    verdict 0 $? "$1"
}

echo "1. Contrôle positif, sans les règles du projet"
trafic_autorise
destinations_interdites passe

echo "2. Avec les règles du projet"
reseaux=$(wh_sous_reseaux eth0) || fatal "sous-réseaux de eth0"
arguments=()
while read -r reseau; do arguments+=(--sous-reseau "$reseau"); done <<<"$reseaux"
bash "$GARDE" regles --wifi wifi0 --eth eth0 "${arguments[@]}" >"$TRAVAIL/regles.nft" ||
    fatal "génération des règles"
nft -f "$TRAVAIL/regles.nft"
verdict 0 $? "la table est acceptée par nftables"
[[ $(wh_etat_table) == nous ]]
verdict 0 $? "la table est reconnue comme celle du projet"
trafic_autorise
destinations_interdites bloque

echo "3. Découverte WS-Discovery"
empreinte_initiale=$(wh_empreinte)
verdict 0 $? "empreinte lisible"
decouverte "la caméra répond à la sonde multicast"
[[ $(nft list set inet "$WH_TABLE" decouverte_wsd) == *elements* ]]
verdict 0 $? "le port de la sonde est inscrit dans l'ensemble temporaire"
[[ $(wh_empreinte) == "$empreinte_initiale" ]]
verdict 0 $? "l'empreinte ignore l'ensemble dynamique"
bloque "caméra → autre port UDP du PC après la sonde" camera udp "$WH_IP_AP" 5000

echo "4. Intégrité"
nft add rule inet "$WH_TABLE" input accept
[[ $(wh_empreinte) != "$empreinte_initiale" ]]
verdict 0 $? "une règle ajoutée change l'empreinte"
nft -f "$TRAVAIL/regles.nft" && [[ $(wh_empreinte) == "$empreinte_initiale" ]]
verdict 0 $? "la pose répétée redonne la même empreinte"
nft add element inet "$WH_TABLE" interdits '{ 11.99.0.0/16 }'
[[ $(wh_empreinte) != "$empreinte_initiale" ]]
verdict 0 $? "un réseau interdit ajouté change l'empreinte"

echo "5. Suppression"
[[ $(autres_regles) == "$reference_autres" ]]
verdict 0 $? "règles préexistantes inchangées pendant la session"
wh_supprimer_table
verdict 0 $? "la table du projet est supprimée"
[[ $(wh_etat_table) == absente ]]
verdict 0 $? "plus aucune table du projet"
[[ $(autres_regles) == "$reference_autres" ]]
verdict 0 $? "règles préexistantes intactes après suppression"

echo
echo "Isolation : $reussis réussis, $echoues échoués."
((echoues == 0))
