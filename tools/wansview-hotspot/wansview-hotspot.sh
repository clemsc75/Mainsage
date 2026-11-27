#!/usr/bin/env bash
# Point d'accès Wi-Fi 2,4 GHz temporaire et isolé pour une caméra Wansview.
# Voir README.md. À lancer avec votre compte : sudo est demandé au besoin.

set -uo pipefail
export LC_ALL=C # sorties de nmcli et iw stables, quelle que soit la langue
umask 077

WH_RACINE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd) || exit 1
# shellcheck source=lib/commun.sh
source "$WH_RACINE/lib/commun.sh" || exit 1
# shellcheck source=lib/detection.sh
source "$WH_RACINE/lib/detection.sh" || exit 1
# shellcheck source=lib/etat.sh
source "$WH_RACINE/lib/etat.sh" || exit 1
# shellcheck source=lib/point-acces.sh
source "$WH_RACINE/lib/point-acces.sh" || exit 1
# shellcheck source=lib/garde-client.sh
source "$WH_RACINE/lib/garde-client.sh" || exit 1
# shellcheck source=lib/restauration.sh
source "$WH_RACINE/lib/restauration.sh" || exit 1
wh_configurer

OPT_SSID=$WH_SSID_DEFAUT
OPT_CANAL=$WH_CANAL_DEFAUT
OPT_WIFI=""
OPT_ETH=""
MOT_DE_PASSE=""
A_RESTAURER=0   # une session de ce processus attend sa restauration
INTERROMPU=0    # arrêt demandé par l'utilisateur

usage() {
    cat <<AIDE
Usage : wansview-hotspot.sh <commande> [options]

  start    démarre le point d'accès et reste au premier plan
  status   affiche l'état
  stop     arrête et restaure le Wi-Fi

Options de « start » :
  --ssid NOM           nom du réseau (défaut : $WH_SSID_DEFAUT)
  --channel N          canal 2,4 GHz (défaut : $WH_CANAL_DEFAUT)
  --wifi-iface NOM     carte Wi-Fi, s'il y en a plusieurs
  --eth-iface NOM      carte Ethernet attendue pour l'accès Internet

Version $WH_VERSION
AIDE
}

lire_options() {
    while (($#)); do
        (($# >= 2)) || wh_fatal "$WH_E_USAGE" "Option inconnue ou sans valeur : $(wh_assainir "$1")"
        case $1 in
            --ssid) wh_valider_ssid "$2" && OPT_SSID=$2 ;;
            --channel) wh_valider_canal "$2" && OPT_CANAL=$2 ;;
            --wifi-iface) wh_valider_iface "$2" && OPT_WIFI=$2 ;;
            --eth-iface) wh_valider_iface "$2" && OPT_ETH=$2 ;;
            *) wh_fatal "$WH_E_USAGE" "Option inconnue : $(wh_assainir "$1")" ;;
        esac || wh_fatal "$WH_E_USAGE" "Valeur invalide pour $1."
        shift 2
    done
}

refuser_root() {
    local uid=$EUID
    wh_mode_test && uid=${WH_TEST_EUID:-$EUID}
    [[ $uid != 0 ]] || wh_fatal "$WH_E_ROOT" \
        "Lancez ce script avec votre compte, sans sudo : il le demandera lui-même."
}

demander_mot_de_passe() {
    local invite=""
    [[ -t 0 ]] && invite="Mot de passe du point d'accès (8 à 63 caractères) : "
    IFS= read -r -s -p "$invite" MOT_DE_PASSE || [[ -n $MOT_DE_PASSE ]] ||
        wh_fatal "$WH_E_USAGE" "Aucun mot de passe saisi."
    [[ -t 0 ]] && echo >&2
    wh_valider_mot_de_passe "$MOT_DE_PASSE" || wh_fatal "$WH_E_USAGE" "Mot de passe refusé."
}

# Exécutée à toute sortie, y compris sur signal.
a_la_sortie() {
    local code=$?
    trap '' INT TERM HUP PIPE # la restauration ne doit pas être interrompue
    trap - EXIT
    MOT_DE_PASSE=""
    if ((A_RESTAURER)); then
        if ! wh_restaurer; then
            code=$WH_E_RESTAURATION
        elif ((INTERROMPU)) && [[ ${WH_ETAT[actif]:-0} == 1 ]]; then
            code=0
        fi
    fi
    exit "$code"
}

# ------------------------------------------------------------------- start

verifier_aucun_reste() {
    local profils
    profils=$(wh_profils_du_projet) ||
        wh_fatal "$WH_E_PREREQUIS" "Liste des profils NetworkManager illisible."
    if wh_etat_present || [[ -n $profils ]] || wh_garde_actif; then
        wh_fatal "$WH_E_OCCUPE" \
            "Des restes d'une session précédente existent. Lancez : wansview-hotspot.sh stop"
    fi
}

# Relève tout ce qu'il faut pour restaurer, avant la première modification.
sauvegarder_etat_initial() { # <wifi> <eth>
    local radio autoconnect uuid_initial uuid_eth session uuid_ap
    local illisible="État initial illisible."
    radio=$(nmcli radio wifi) || wh_fatal "$WH_E_PREREQUIS" "$illisible"
    autoconnect=$(nmcli -g GENERAL.AUTOCONNECT device show "$1") ||
        wh_fatal "$WH_E_PREREQUIS" "$illisible"
    uuid_initial=$(nmcli -g GENERAL.CON-UUID device show "$1") ||
        wh_fatal "$WH_E_PREREQUIS" "$illisible"
    uuid_eth=$(nmcli -g GENERAL.CON-UUID device show "$2") ||
        wh_fatal "$WH_E_PREREQUIS" "$illisible"
    session=$(wh_nouvel_uuid) || wh_fatal "$WH_E_PREREQUIS" "$illisible"
    uuid_ap=$(wh_nouvel_uuid) || wh_fatal "$WH_E_PREREQUIS" "$illisible"

    WH_ETAT=([session]=$session [wifi]=$1 [eth]=$2 [uuid_ap]=$uuid_ap [ssid]=$OPT_SSID
        [canal]=$OPT_CANAL [uuid_initial]=$uuid_initial [radio_initiale]=$radio
        [autoconnect_initial]=$autoconnect [uuid_eth]=$uuid_eth [garde_lancee]=0
        [wifi_modifie]=0 [actif]=0)
    local cle
    for cle in "${WH_CLES_ETAT[@]}"; do
        wh_etat_valeur_valide "$cle" "${WH_ETAT[$cle]}" ||
            wh_fatal "$WH_E_PREREQUIS" "État initial inattendu ($cle)."
    done
    WH_SESSION=$session

    local echec="Impossible d'enregistrer l'état initial."
    wh_lister_configuration_permanente | wh_ecrire_atomique "$WH_DIR/etc-avant" 0600 ||
        wh_fatal "$WH_E_PREREQUIS" "$echec"
    wh_routes_hors_wifi "$1" | wh_ecrire_atomique "$WH_DIR/routes-avant" 0600 ||
        wh_fatal "$WH_E_PREREQUIS" "$echec"
    wh_etat_enregistrer || wh_fatal "$WH_E_PREREQUIS" "$echec"
}

afficher_demarrage() {
    wh_info ""
    wh_info "Point d'accès actif."
    wh_info "  SSID        : ${WH_ETAT[ssid]} (canal ${WH_ETAT[canal]}, 2,4 GHz, WPA2)"
    wh_info "  IP Wi-Fi    : $WH_IP_AP/$WH_PREFIXE_AP sur ${WH_ETAT[wifi]}"
    wh_info "  Plage DHCP  : $WH_DHCP_DEBUT à $WH_DHCP_FIN"
    wh_info "  Ethernet    : ${WH_ETAT[eth]} connectée, route Internet"
    wh_info "  Isolation   : règles posées et surveillées toutes les $WH_INTERVALLE s"
    wh_info "                (non prouvée tant que vos tests réels n'ont pas réussi)"
    wh_info "  Les appareils connectés au point d'accès peuvent communiquer entre eux."
    wh_info ""
    wh_info "Ctrl+C ou « wansview-hotspot.sh stop » pour arrêter et restaurer."
}

# Ne revient qu'en cas d'anomalie ; un arrêt demandé passe par les signaux.
surveiller() {
    local motif
    while :; do
        sleep "$WH_INTERVALLE" 9>&-
        if ! wh_point_acces_actif "${WH_ETAT[wifi]}" "${WH_ETAT[uuid_ap]}"; then
            motif="Le point d'accès n'est plus actif"
        elif ! wh_garde_sain "${WH_ETAT[session]}"; then
            motif="Le garde ne répond plus : isolation non garantie"
        else
            continue
        fi
        wh_erreur "$motif (garde : $(wh_motif_garde "${WH_ETAT[session]}"))."
        exit "$WH_E_ISOLATION"
    done
}

cmd_start() {
    lire_options "$@"
    wh_verifier_dependances || exit
    wh_preparer_repertoires || exit
    wh_verrouiller "" ||
        wh_fatal "$WH_E_OCCUPE" "Une autre instance est en cours (voir « status » ou « stop »)."
    wh_verifier_nm || exit
    wh_verifier_permissions || exit
    verifier_aucun_reste

    local eth wifi
    eth=$(wh_choisir_ethernet "$OPT_ETH") || exit
    wifi=$(wh_choisir_wifi "$OPT_WIFI" "$OPT_CANAL") || exit
    wh_verifier_conflit_routes "$wifi" || exit
    demander_mot_de_passe

    trap a_la_sortie EXIT
    trap 'INTERROMPU=1; exit 130' INT
    trap 'INTERROMPU=1; exit 143' TERM
    trap 'INTERROMPU=1; exit 129' HUP

    sauvegarder_etat_initial "$wifi" "$eth"
    A_RESTAURER=1
    local uuid=${WH_ETAT[uuid_ap]} session=${WH_ETAT[session]}

    wh_creer_profil "$uuid" "$wifi" "$OPT_SSID" "$OPT_CANAL" || exit
    wh_verifier_non_persistance "$uuid" "$WH_DIR/etc-avant" || exit

    # sudo est obtenu avant de toucher à la connexion Wi-Fi.
    wh_installer_garde || exit
    wh_etat_definir garde_lancee 1 || exit
    if ! wh_lancer_garde "$wifi" "$eth" "$uuid" "$session"; then
        # Service jamais démarré : aucune table à nettoyer.
        wh_garde_actif || wh_etat_definir garde_lancee 0
        exit "$WH_E_ISOLATION"
    fi

    wh_etat_definir wifi_modifie 1 || exit
    wh_liberer_wifi "$wifi" "${WH_ETAT[radio_initiale]}" || exit
    wh_attendre_garde "$session" || exit

    wh_activer_point_acces "$uuid" "$MOT_DE_PASSE" || exit
    MOT_DE_PASSE=""
    if ! wh_point_acces_actif "$wifi" "$uuid" || ! wh_adresse_point_acces "$wifi"; then
        wh_fatal "$WH_E_ACTIVATION" "Le point d'accès n'a pas été constaté actif."
    fi
    wh_verifier_non_persistance "$uuid" "$WH_DIR/etc-avant" || exit
    wh_garde_sain "$session" ||
        wh_fatal "$WH_E_ISOLATION" "Isolation perdue pendant l'activation : $(wh_motif_garde "$session")."

    wh_etat_definir actif 1 || exit
    afficher_demarrage
    surveiller
}

# ------------------------------------------------------------------ status

afficher_ethernet() { # <interface ou vide>
    local eth=$1 route info
    route=$(wh_iface_route_internet) || route=aucune
    [[ -n $eth ]] || eth=$route
    info=$(wh_peripherique "$eth") || info=""
    if [[ ${info%%:*} != ethernet ]]; then
        echo "Ethernet        : non connectée (route Internet par $(wh_assainir "$route"))"
        return
    fi
    echo "Ethernet        : $eth (${info#*:}), route Internet par $(wh_assainir "$route")"
}

afficher_clients() { # <wifi>
    local voisins stations ligne
    stations=$(iw dev "$1" station dump 2>/dev/null | grep -c '^Station ')
    echo "Appareils Wi-Fi : $stations associé(s)"
    voisins=$(ip -4 neigh show dev "$1" 2>/dev/null)
    [[ -n $voisins ]] || return 0
    while IFS= read -r ligne; do echo "  $ligne"; done <<<"$voisins"
}

cmd_status() {
    (($# == 0)) || wh_fatal "$WH_E_USAGE" "« status » n'accepte aucune option."
    wh_preparer_repertoires || exit
    WH_JOURNAL=""

    if ! wh_etat_present; then
        echo "Point d'accès   : inactif"
        afficher_ethernet ""
        if [[ -n $(wh_profils_du_projet) ]] || wh_garde_actif; then
            echo "Restes détectés : lancez « wansview-hotspot.sh stop »."
        fi
        return 0
    fi

    wh_etat_charger || exit
    local wifi=${WH_ETAT[wifi]} session=${WH_ETAT[session]} actif=0 sain=0 pid debut
    wh_point_acces_actif "$wifi" "${WH_ETAT[uuid_ap]}" && actif=1
    wh_garde_sain "$session" && sain=1
    pid=$(wh_lire_cle "$WH_DIR/verrou" pid)
    debut=$(wh_lire_cle "$WH_DIR/verrou" debut)

    if ((actif)); then
        echo "Point d'accès   : actif"
    else
        echo "Point d'accès   : non actif (démarrage, arrêt ou restes)"
    fi
    echo "SSID            : ${WH_ETAT[ssid]} (canal ${WH_ETAT[canal]})"
    echo "IP Wi-Fi        : $WH_IP_AP/$WH_PREFIXE_AP sur $wifi"
    echo "Plage DHCP      : $WH_DHCP_DEBUT à $WH_DHCP_FIN"
    afficher_ethernet "${WH_ETAT[eth]}"
    if ((sain)); then
        echo "Isolation       : confirmée par le garde il y a $(wh_age_signal "$session") s"
    else
        echo "Isolation       : NON GARANTIE ($(wh_motif_garde "$session"))"
    fi
    if ! wh_processus_vivant "$pid" "$debut"; then
        echo "Script « start » : arrêté. Lancez « wansview-hotspot.sh stop » pour restaurer."
    fi
    ((actif)) && afficher_clients "$wifi"
    ((actif && !sain)) && return "$WH_E_ISOLATION"
    return 0
}

# -------------------------------------------------------------------- stop

cmd_stop() {
    (($# == 0)) || wh_fatal "$WH_E_USAGE" "« stop » n'accepte aucune option."
    wh_preparer_repertoires || exit
    local signale=0 pid debut

    # Si « start » tourne, c'est lui qui restaure : on le lui demande.
    exec 9<>"$WH_DIR/verrou" || exit "$WH_E_OCCUPE"
    if ! flock -n 9; then
        pid=$(wh_lire_cle "$WH_DIR/verrou" pid)
        debut=$(wh_lire_cle "$WH_DIR/verrou" debut)
        if wh_processus_vivant "$pid" "$debut"; then
            wh_info "Demande d'arrêt envoyée au point d'accès en cours."
            kill -TERM "$pid" && signale=1
        fi
        flock -w "$((WH_DELAI_ARRET + 60))" 9 ||
            wh_fatal "$WH_E_OCCUPE" "L'instance en cours ne se termine pas."
    fi
    wh_verrouiller "" || wh_fatal "$WH_E_OCCUPE" "Verrou indisponible."

    trap '' INT TERM HUP PIPE
    if wh_etat_present; then
        wh_etat_charger || exit
        wh_restaurer
    elif ((signale)); then
        wh_info "Instance arrêtée, aucune restauration en attente."
    else
        wh_nettoyer_orphelins
    fi
}

main() {
    local commande=${1:-}
    (($#)) && shift
    case $commande in
        start | status | stop)
            refuser_root
            "cmd_$commande" "$@"
            ;;
        -h | --help | help) usage ;;
        *)
            usage >&2
            exit "$WH_E_USAGE"
            ;;
    esac
}

main "$@"
