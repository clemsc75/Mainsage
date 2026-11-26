#!/usr/bin/env bash
# Outils communs aux tests : bac à sable, scénario simulé et assertions.
# Aucune commande réseau réelle ne doit être accessible depuis le bac à sable.
# shellcheck disable=SC2034  # variables utilisées par les fichiers de test

RACINE_OUTIL=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
RACINE_FAUX="$RACINE_OUTIL/tests/faux"

# Commandes qui ne doivent jamais être les vraies pendant un test.
COMMANDES_SIMULEES=(nmcli ip iw nft sudo systemd-run systemctl ping install dnsmasq nc python3)
# Outils sans effet sur le réseau, liés un par un dans le bac à sable.
OUTILS_AUTORISES=(bash env cat mkdir rmdir rm mv cp chmod ln ls sleep date grep sed awk sort
    cmp diff find stat sha256sum mktemp dirname basename readlink head tail cut tr wc flock
    touch setsid)

UUID_INITIAL=11111111-1111-4111-8111-111111111111
UUID_ETHERNET=22222222-2222-4222-8222-222222222222
IFACE_ETH=enp1s0
IFACE_WIFI=wlp2s0

# ---------------------------------------------------------------- bac à sable

bac_creer() {
    BAC=$(mktemp -d "${TMPDIR:-/tmp}/wh-test.XXXXXX") || exit 1
    FAUX="$BAC/faux"
    mkdir -p "$BAC/bin" "$BAC/home" "$BAC/xdg" "$BAC/run" "$BAC/sys/class/net" \
        "$BAC/etc/netplan" "$BAC/etc/NetworkManager/system-connections" \
        "$FAUX/nm" "$FAUX/dev" "$FAUX/conn" "$FAUX/ip" "$FAUX/phy" "$FAUX/nft" \
        "$FAUX/unit" "$FAUX/echec"
    chmod 700 "$BAC/xdg"
    : >"$FAUX/appels.log"

    local outil chemin
    for outil in "${OUTILS_AUTORISES[@]}"; do
        chemin=$(command -v "$outil") || { echo "outil absent : $outil" >&2; exit 1; }
        ln -s "$chemin" "$BAC/bin/$outil"
    done
    for outil in "${COMMANDES_SIMULEES[@]}"; do
        ln -s "$RACINE_FAUX/$outil" "$BAC/bin/$outil"
    done

    # Mot de passe d'essai généré à chaque exécution : aucun secret dans le dépôt.
    MDP="Essai-$RANDOM-$RANDOM"
    printf '802-11-wireless-security.psk:%s\n' "$MDP" | sha256sum >"$FAUX/psk_sha"
}

# Refuse de lancer un test si une commande simulée pourrait être la vraie.
bac_verifier() {
    local commande trouve cible
    for commande in "${COMMANDES_SIMULEES[@]}"; do
        trouve=$(env -i PATH="$BAC/bin" "$BAC/bin/bash" -c "command -v $commande")
        cible=$(readlink -f "$trouve")
        if [[ $trouve != "$BAC/bin/$commande" || $cible != "$RACINE_FAUX/$commande" || ! -x $cible ]]; then
            echo "BAC À SABLE NON SÛR : $commande -> ${trouve:-introuvable} (${cible:-?})" >&2
            exit 99
        fi
    done
}

# Exécute une commande dans un environnement vierge limité au bac à sable.
# DBUS_SYSTEM_BUS_ADDRESS pointe dans le vide : même un vrai nmcli resterait muet.
bac_variables() {
    BAC_VARIABLES=(PATH="$BAC/bin" HOME="$BAC/home" XDG_RUNTIME_DIR="$BAC/xdg"
        DBUS_SYSTEM_BUS_ADDRESS="unix:path=$BAC/pas-de-bus"
        WH_FAUX="$FAUX" WH_BAC="$BAC"
        WH_MODE_TEST=1
        WH_TEST_ETC="$BAC/etc" WH_TEST_SYS="$BAC/sys"
        WH_TEST_RUN="$BAC/run/wansview-hotspot"
        WH_TEST_INTERVALLE=0.1
        WH_TEST_DELAI_GARDE="${DELAI_GARDE:-5}"
        WH_TEST_DELAI_ARRET="${DELAI_ARRET:-5}"
        WH_TEST_DELAI_ACTIVATION="${DELAI_ACTIVATION:-60}"
        WH_TEST_AGE_MAX="${AGE_MAX:-6}")
}

bac_env() {
    bac_variables
    env -i "${BAC_VARIABLES[@]}" "$@"
}

# À lancer en arrière-plan : le processus de $! est alors la commande elle-même.
bac_exec() {
    bac_variables
    exec env -i "${BAC_VARIABLES[@]}" "$@"
}

bac_detruire() {
    local fichier pid
    if [[ -n ${PID_START:-} ]]; then
        kill -KILL -- "-$PID_START" 2>/dev/null
    fi
    for fichier in "$FAUX"/unit/*.pid "$BAC"/*.pid; do
        [[ -f $fichier ]] || continue
        read -r pid <"$fichier"
        kill -KILL "$pid" 2>/dev/null
    done
    # Laisse les enveloppes en arrière-plan se terminer avant d'effacer.
    sleep 0.1
    rm -rf "$BAC" 2>/dev/null || { sleep 0.3; rm -rf "$BAC"; }
}

# ------------------------------------------------------------------ scénario

# faux_peripherique <nom> <type> <état> [uuid] [adresse CIDR]
faux_peripherique() {
    local d="$FAUX/dev/$1"
    mkdir -p "$d"
    echo "$2" >"$d/type"
    echo "$3" >"$d/state"
    echo "${4:-}" >"$d/uuid"
    echo yes >"$d/autoconnect"
    echo managed >"$d/iwtype"
    echo "${5:-}" >"$d/addr"
}

# faux_wifi <nom> <phy> : entrées sysfs d'une carte Wi-Fi
faux_wifi() {
    local s="$BAC/sys/class/net/$1/phy80211"
    mkdir -p "$s/rfkill0"
    echo "$2" >"$s/name"
    echo 0 >"$s/rfkill0/soft"
    echo 0 >"$s/rfkill0/hard"
}

faux_connexion() { # <uuid> <nom> <fichier>
    mkdir -p "$FAUX/conn/$1"
    echo "$2" >"$FAUX/conn/$1/name"
    echo "$3" >"$FAUX/conn/$1/filename"
    echo infrastructure >"$FAUX/conn/$1/mode"
}

faux_phy() { # <phy> : bande 2,4 GHz avec mode AP, canaux 12 et 13 en "no IR"
    {
        echo "Wiphy $1"
        echo "	Supported interface modes:"
        echo "		 * managed"
        echo "		 * AP"
        echo "		 * AP/VLAN"
        echo "		 * P2P-client"
        echo "	Band 1:"
        echo "		Frequencies:"
        local canal
        for canal in 1 2 3 4 5 6 7 8 9 10 11; do
            echo "			* $((2407 + canal * 5)).0 MHz [$canal] (20.0 dBm)"
        done
        echo "			* 2467.0 MHz [12] (20.0 dBm) (no IR)"
        echo "			* 2472.0 MHz [13] (20.0 dBm) (no IR)"
        echo "			* 2484.0 MHz [14] (disabled)"
        echo "	Band 2:"
        echo "		Frequencies:"
        echo "			* 5180.0 MHz [36] (23.0 dBm)"
    } >"$FAUX/phy/$1"
}

# Portable avec Ethernet (route Internet) et Wi-Fi connecté à un réseau.
bac_scenario_defaut() {
    echo running >"$FAUX/nm/running"
    echo enabled >"$FAUX/nm/radio"
    local p
    : >"$FAUX/nm/permissions"
    for p in network-control settings.modify.system wifi.share.protected enable-disable-wifi; do
        echo "org.freedesktop.NetworkManager.$p:yes" >>"$FAUX/nm/permissions"
    done

    faux_peripherique "$IFACE_ETH" ethernet connected "$UUID_ETHERNET" 192.168.50.20/24
    faux_peripherique "$IFACE_WIFI" wifi connected "$UUID_INITIAL" 172.20.36.44/24
    faux_peripherique tailscale0 tun "connected (externally)" "" 100.64.0.3/32
    faux_peripherique docker0 bridge "connected (externally)" "" 172.17.0.1/16
    faux_wifi "$IFACE_WIFI" phy0
    faux_phy phy0

    faux_connexion "$UUID_ETHERNET" netplan-eth \
        "/run/NetworkManager/system-connections/netplan-eth.nmconnection"
    faux_connexion "$UUID_INITIAL" reseau-habituel \
        "/run/NetworkManager/system-connections/netplan-wifi.nmconnection"

    echo "1.1.1.1 via 192.168.50.1 dev $IFACE_ETH src 192.168.50.20 uid 1000" >"$FAUX/ip/route_get"
    {
        echo "default via 192.168.50.1 dev $IFACE_ETH proto dhcp src 192.168.50.20 metric 100"
        echo "default via 172.20.36.254 dev $IFACE_WIFI proto dhcp src 172.20.36.44 metric 600"
        echo "172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown"
        echo "172.20.36.0/24 dev $IFACE_WIFI proto kernel scope link src 172.20.36.44 metric 600"
        echo "192.168.50.0/24 dev $IFACE_ETH proto kernel scope link src 192.168.50.20 metric 100"
    } >"$FAUX/ip/routes"

    echo "network: {version: 2}" >"$BAC/etc/netplan/00-installer.yaml"
    echo "table inet existante" >"$FAUX/nft/autres"
}

faux_echec() { : >"$FAUX/echec/$1"; }
faux_lire() { cat "$FAUX/$1" 2>/dev/null; }
appels() { cat "$FAUX/appels.log"; }

# ---------------------------------------------------------------- assertions

echec() {
    printf 'ÉCHEC : %s\n' "$*" >&2
    exit 1
}

egal() { [[ $1 == "$2" ]] || echec "${3:-valeurs différentes} : attendu « $1 », obtenu « $2 »"; }
contient() { [[ $1 == *"$2"* ]] || echec "${3:-texte absent} : « $2 » introuvable dans :"$'\n'"$1"; }
ne_contient() { [[ $1 != *"$2"* ]] || echec "${3:-texte interdit} : « $2 » présent dans :"$'\n'"$1"; }
existe() { [[ -e $1 ]] || echec "fichier attendu : $1"; }
absent() { [[ ! -e $1 ]] || echec "fichier inattendu : $1"; }

# Exécute et capture SORTIE et CODE.
executer() {
    SORTIE=$("$@" 2>&1)
    CODE=$?
}

# Exécute du Bash avec les bibliothèques chargées, dans le bac à sable.
avec_libs() {
    # shellcheck disable=SC2016  # développé par le bash enfant
    executer bac_env bash -c '
        racine=$1; code=$2; shift 2
        for f in commun detection regles etat point-acces garde-client restauration; do
            [[ -f $racine/lib/$f.sh ]] && source "$racine/lib/$f.sh"
        done
        wh_configurer
        eval "$code"
    ' _ "$RACINE_OUTIL" "$@"
}

reussit() { # <code bash> [arguments]
    avec_libs "$@"
    [[ $CODE -eq 0 ]] || echec "devait réussir : $* (code $CODE) $SORTIE"
}

refuse() {
    avec_libs "$@"
    [[ $CODE -ne 0 ]] || echec "devait échouer : $*"
    [[ $CODE -ne 127 ]] || echec "commande introuvable : $* $SORTIE"
}

# attendre <description> <commande...> : réessaie pendant 8 secondes au plus.
attendre() {
    local quoi=$1 i
    shift
    for ((i = 0; i < 160; i++)); do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.05
    done
    echec "délai dépassé : $quoi"
}
