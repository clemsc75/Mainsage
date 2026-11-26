#!/usr/bin/env bash
# Vérification sur la vraie machine, à lancer vous-même, en lecture seule :
#
#   tests/verification-reelle.sh avant                    avant « start »
#   tests/verification-reelle.sh pendant [--camera IP]    point d'accès actif
#   tests/verification-reelle.sh apres                    après « stop »
#
# Seul « sudo nft -s list ruleset » demande les droits administrateur. Les
# relevés restent dans votre dossier d'état privé, hors du dépôt.

set -uo pipefail
export LC_ALL=C
umask 077

WH_RACINE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
# shellcheck source=lib/commun.sh
source "$WH_RACINE/lib/commun.sh" || exit 1
# shellcheck source=lib/detection.sh
source "$WH_RACINE/lib/detection.sh" || exit 1
# shellcheck source=lib/etat.sh
source "$WH_RACINE/lib/etat.sh" || exit 1
# shellcheck source=lib/point-acces.sh
source "$WH_RACINE/lib/point-acces.sh" || exit 1
# shellcheck source=lib/restauration.sh
source "$WH_RACINE/lib/restauration.sh" || exit 1
wh_configurer

PHASE="" CAMERA="" echecs=0 ETH="" WIFI=""

usage() {
    echo "Usage : verification-reelle.sh avant|pendant|apres [--camera IP]" >&2
    exit "$WH_E_USAGE"
}

ok() { printf 'OK      %s\n' "$*"; }
rate() {
    printf 'ÉCHEC   %s\n' "$*"
    echecs=$((echecs + 1))
}

lire_arguments() {
    PHASE=${1:-}
    [[ $PHASE == @(avant|pendant|apres) ]] || usage
    shift
    while (($#)); do
        [[ $1 == --camera && $# -ge 2 && $PHASE == pendant ]] || usage
        wh_ip_vers_entier "$2" >/dev/null || usage
        CAMERA=$2
        shift 2
    done
}

# Première carte d'un type donné.
premiere_interface() { # <type>
    local liste nom type
    liste=$(wh_peripheriques) || return 1
    while IFS=: read -r nom type _; do
        if [[ $type == "$1" ]] && wh_valider_iface "$nom"; then
            echo "$nom"
            return 0
        fi
    done <<<"$liste"
    return 1
}

# Connexion et adresses de l'Ethernet, sans les durées de bail qui varient.
releve_ethernet() {
    local adresses
    wh_peripherique "$ETH" || return 1
    nmcli -g GENERAL.CON-UUID device show "$ETH" || return 1
    adresses=$(ip -4 -o addr show dev "$ETH") || return 1
    awk '{ for (i = 1; i < NF; i++) if ($i == "inet") print $(i + 1) }' <<<"$adresses"
    echo "route Internet : $(wh_iface_route_internet)"
}

relever() { # <dossier>
    # shellcheck disable=SC2024  # le relevé doit appartenir à l'utilisateur
    releve_ethernet >"$1/ethernet" &&
        wh_routes_hors_wifi "$WIFI" >"$1/routes" &&
        wh_lister_configuration_permanente >"$1/etc" &&
        sudo nft -s list ruleset >"$1/nft"
}

comparer() { # <fichier> <description>
    if cmp -s "$DOSSIER/avant/$1" "$DOSSIER/$PHASE/$1"; then
        ok "$2 : inchangé"
    else
        rate "$2 : différent du relevé « avant »"
        diff "$DOSSIER/avant/$1" "$DOSSIER/$PHASE/$1" | head -n 20
    fi
}

verifier_internet() {
    if ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
        ok "Internet joignable depuis le PC"
    else
        rate "Internet injoignable depuis le PC (ICMP vers 1.1.1.1)"
    fi
}

table_du_projet_presente() { grep -q "^table inet $WH_TABLE\b" "$DOSSIER/$PHASE/nft"; }

verifier_pendant() {
    local table perdues=0
    if table_du_projet_presente && grep -q "comment \"$WH_COMMENTAIRE\"" "$DOSSIER/pendant/nft"; then
        ok "table nftables du projet présente"
    else
        rate "table nftables du projet absente : aucune isolation"
    fi
    # NetworkManager ajoute ses règles pendant la session : on vérifie seulement
    # qu'aucune table antérieure n'a disparu.
    while read -r table; do
        grep -qxF "$table" "$DOSSIER/pendant/nft" || {
            rate "table disparue : $table"
            perdues=1
        }
    done < <(grep '^table ' "$DOSSIER/avant/nft")
    ((perdues)) || ok "tables nftables antérieures toujours présentes"
}

verifier_camera() {
    local port ouverts=0
    echo "Caméra $CAMERA :"
    for port in 554 80 443; do
        if nc -z -w 2 "$CAMERA" "$port" >/dev/null 2>&1; then
            echo "  port $port ouvert"
            ouverts=$((ouverts + 1))
        else
            echo "  port $port fermé ou filtré"
        fi
    done
    if ((ouverts)); then
        ok "la caméra répond au PC"
    else
        rate "la caméra ne répond sur aucun port testé"
    fi
}

verifier_onvif() {
    echo "Découverte ONVIF :"
    python3 -B "$WH_RACINE/outils/decouverte-onvif.py" --source "$WH_IP_AP" ||
        echo "  aucune réponse (ONVIF désactivé, caméra absente ou point d'accès inactif)"
}

liste_telephone() {
    cat <<LISTE

À contrôler depuis un téléphone connecté au point d'accès :
  [ ] une adresse entre $WH_DHCP_DEBUT et $WH_DHCP_FIN est attribuée
  [ ] un site web s'ouvre (Internet et DNS)
  [ ] l'interface de votre box ou routeur local ne s'ouvre pas
  [ ] une autre machine du réseau Ethernet est injoignable
  [ ] ssh vers $WH_IP_AP (port 22) échoue, ainsi que le port 111
  [ ] une adresse Tailscale (100.64.0.0/10) est injoignable
  [ ] après coupure du Wi-Fi du téléphone, la reconnexion fonctionne
      sans que le PC redemande le mot de passe
LISTE
}

main() {
    lire_arguments "$@"
    [[ $EUID -ne 0 ]] || wh_fatal "$WH_E_ROOT" "Lancez ce script sans sudo."
    wh_preparer_repertoires || exit
    # shellcheck disable=SC2034  # pas de journal pour une simple vérification
    WH_JOURNAL=""
    DOSSIER="${XDG_STATE_HOME:-$HOME/.local/state}/wansview-hotspot/verification"
    if [[ $PHASE != avant && ! -s $DOSSIER/avant/nft ]]; then
        wh_fatal "$WH_E_USAGE" "Relevé initial absent : lancez d'abord la phase « avant »."
    fi
    mkdir -p "$DOSSIER/$PHASE" || exit "$WH_E_PREREQUIS"

    if [[ $PHASE == avant ]]; then
        ETH=$(wh_choisir_ethernet "") || exit
        echo "$ETH" >"$DOSSIER/avant/iface-eth"
    else
        { read -r ETH <"$DOSSIER/avant/iface-eth"; } 2>/dev/null
        wh_valider_iface "$ETH" || wh_fatal "$WH_E_USAGE" "Relevé « avant » invalide."
    fi
    WIFI=$(premiere_interface wifi) || wh_fatal "$WH_E_PREREQUIS" "Aucune carte Wi-Fi."
    relever "$DOSSIER/$PHASE" || wh_fatal "$WH_E_PREREQUIS" "Relevé impossible."

    case $PHASE in
        avant)
            if table_du_projet_presente; then
                rate "une table du projet existe déjà : lancez « stop »"
            fi
            ;;
        *)
            comparer ethernet "Ethernet"
            comparer routes "routes hors Wi-Fi"
            comparer etc "fichiers de /etc/netplan et system-connections"
            ;;
    esac
    case $PHASE in
        pendant)
            verifier_pendant
            [[ -z $CAMERA ]] || verifier_camera
            verifier_onvif
            ;;
        apres)
            comparer nft "règles nftables du système"
            if table_du_projet_presente; then
                rate "la table du projet est encore présente"
            else
                ok "aucune table du projet"
            fi
            ;;
    esac
    verifier_internet
    [[ $PHASE != pendant ]] || liste_telephone

    echo
    echo "Phase « $PHASE » : $echecs échec(s). Relevés : $DOSSIER/$PHASE"
    ((echecs == 0))
}

main "$@"
