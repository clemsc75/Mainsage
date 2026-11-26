#!/usr/bin/env bash
# Garde du point d'accès, exécuté en root dans un service systemd temporaire.
# Il pose l'isolation nftables, la surveille et, au moindre problème, coupe le
# point d'accès AVANT de retirer les règles. En cas de doute, les règles restent.
#
# Sous-commandes :
#   surveiller   --wifi I --eth I --uuid U --pid N --debut N --session U
#   apres-arret  --wifi I --uuid U --session U   (ExecStopPost du service)
#   nettoyer                                      (table orpheline)
#   regles       --wifi I --eth I [--sous-reseau CIDR]...
#   empreinte

set -uo pipefail

# Chemin fixe : seul un test non privilégié peut le remplacer.
[[ $EUID -ne 0 && ${WH_MODE_TEST:-} == 1 ]] || PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C
umask 022

ici=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
# shellcheck source=lib/commun.sh
source "$ici/lib/commun.sh" || exit 1
# shellcheck source=lib/regles.sh
source "$ici/lib/regles.sh" || exit 1
wh_configurer

WIFI="" ETH="" UUID="" PID="" DEBUT="" SOUS_RESEAUX=()

# --------------------------------------------------------------------- options

lire_options() { # <options autorisées> -- <arguments>
    local autorisees=" $1 " option valeur
    shift 2
    while (($#)); do
        option=$1
        [[ $autorisees == *" $option "* && $# -ge 2 ]] ||
            wh_fatal "$WH_E_USAGE" "Option invalide : $(wh_assainir "$option")"
        valeur=$2
        shift 2
        case $option in
            --wifi) wh_valider_iface "$valeur" && WIFI=$valeur ;;
            --eth) wh_valider_iface "$valeur" && ETH=$valeur ;;
            --uuid) wh_valider_uuid "$valeur" && UUID=$valeur ;;
            --session) wh_valider_uuid "$valeur" && WH_SESSION=$valeur ;;
            --pid) wh_valider_pid "$valeur" && PID=$valeur ;;
            --debut) wh_valider_entier "$valeur" && DEBUT=$valeur ;;
            --sous-reseau) wh_valider_cidr "$valeur" && SOUS_RESEAUX+=("$valeur") ;;
        esac || wh_fatal "$WH_E_USAGE" "Valeur invalide pour $option."
    done
}

exiger() { # <nom de variable>...
    local nom
    for nom in "$@"; do
        [[ -n ${!nom:-} ]] || wh_fatal "$WH_E_USAGE" "Option manquante : ${nom}."
    done
}

exiger_root() {
    [[ $EUID -eq 0 ]] || wh_mode_test ||
        wh_fatal "$WH_E_ROOT" "Cette sous-commande doit être exécutée en root."
}

# ------------------------------------------------------------------------ état

# Signal de vie lisible par le script principal.
ecrire_etat() { # <statut> <table> <motif>
    local instant
    instant=$(wh_uptime) || instant=0
    printf 'session=%s\nstatut=%s\ntable=%s\nuptime=%s\nmotif=%s\n' \
        "${WH_SESSION:-}" "$1" "$2" "$instant" "$3" |
        wh_ecrire_atomique "$WH_RUN/etat" 0644
}

# Affiche « actif », « inactif », « transition » ou « inconnu ».
etat_point_acces() {
    local infos courant en_ap=0
    infos=$(iw dev "$WIFI" info 2>/dev/null) || { echo inconnu; return; }
    courant=$(nmcli -g GENERAL.CON-UUID device show "$WIFI" 2>/dev/null) || { echo inconnu; return; }
    [[ $infos == *$'\ttype AP'* ]] && en_ap=1
    if ((en_ap)) && [[ $courant == "$UUID" ]]; then
        echo actif
    elif ((!en_ap)) && [[ $courant != "$UUID" ]]; then
        echo inactif
    else
        echo transition
    fi
}

profil_absent() {
    local liste
    liste=$(nmcli -t -f UUID,NAME connection show 2>/dev/null) || return 1
    [[ $'\n'"$liste" != *$'\n'"$UUID:"* ]]
}

# Coupe le point d'accès et ne réussit que si l'arrêt est constaté.
couper_point_acces() {
    local essai
    for essai in 1 2 3; do
        nmcli --wait 10 connection down uuid "$UUID" >/dev/null 2>&1
        nmcli --wait 10 connection delete uuid "$UUID" >/dev/null 2>&1
        [[ $(etat_point_acces) == inactif ]] && profil_absent && return 0
        ((essai < 3)) && sleep "$WH_INTERVALLE"
    done
    return 1
}

# Repose la table si elle manque ou a changé, sans toucher à une table étrangère.
retablir_regles() { # <empreinte de référence>
    [[ $(wh_empreinte) == "$1" ]] && return 0
    wh_alerte "Règles modifiées : rétablissement avant la coupure."
    wh_poser_regles "$WIFI" "$ETH" "${SOUS_RESEAUX[@]}"
}

# arret_securise <motif> : coupe, constate, puis seulement retire la table.
arret_securise() {
    trap '' TERM INT HUP
    local motif=$1
    wh_info "Arrêt sécurisé : $motif."
    ecrire_etat arret presente "$motif"
    if couper_point_acces; then
        if wh_supprimer_table; then
            ecrire_etat arrete absente "$motif"
            wh_info "Point d'accès arrêté, table du projet supprimée."
            return 0
        fi
    else
        wh_erreur "L'arrêt du point d'accès n'est pas confirmé : les règles sont conservées."
    fi
    ecrire_etat arrete conservee "$motif"
    return "$WH_E_ISOLATION"
}

# ------------------------------------------------------------- sous-commandes

cmd_surveiller() {
    lire_options "--wifi --eth --uuid --pid --debut --session" -- "$@"
    exiger WIFI ETH UUID PID DEBUT WH_SESSION
    exiger_root

    local reseaux reference
    if ! wh_processus_vivant "$PID" "$DEBUT"; then
        ecrire_etat erreur absente "processus principal introuvable"
        wh_fatal "$WH_E_ISOLATION" "Processus principal introuvable."
    fi
    if ! reseaux=$(wh_sous_reseaux "$ETH"); then
        ecrire_etat erreur absente "sous-réseaux Ethernet illisibles"
        wh_fatal "$WH_E_ISOLATION" "Sous-réseaux de l'Ethernet illisibles."
    fi
    SOUS_RESEAUX=()
    [[ -z $reseaux ]] || mapfile -t SOUS_RESEAUX <<<"$reseaux"

    if ! wh_poser_regles "$WIFI" "$ETH" "${SOUS_RESEAUX[@]}"; then
        ecrire_etat erreur absente "pose des règles nftables impossible"
        wh_fatal "$WH_E_ISOLATION" "Pose des règles nftables impossible."
    fi
    if ! reference=$(wh_empreinte); then
        ecrire_etat erreur presente "règles illisibles"
        wh_fatal "$WH_E_ISOLATION" "Règles posées mais illisibles."
    fi

    trap 'arret_securise "signal reçu"; exit $?' TERM INT HUP
    ecrire_etat pret presente ""
    wh_info "Isolation en place sur $WIFI, Internet par $ETH."

    local debut_attente maintenant actuels point vu_actif=0 statut=pret motif=""
    debut_attente=$(wh_uptime)
    while [[ -z $motif ]]; do
        # « wait » est interrompu immédiatement par un signal, contrairement à « sleep ».
        sleep "$WH_INTERVALLE" &
        wait $!
        maintenant=$(wh_uptime)
        if ! wh_processus_vivant "$PID" "$DEBUT"; then
            motif="processus principal disparu"
        elif [[ $(wh_empreinte) != "$reference" ]]; then
            motif="règles nftables modifiées ou illisibles"
            retablir_regles "$reference"
        elif ! actuels=$(wh_sous_reseaux "$ETH") || [[ $actuels != "$reseaux" ]]; then
            motif="réseaux de l'Ethernet modifiés"
        else
            point=$(etat_point_acces)
            if [[ $point == actif ]]; then
                vu_actif=1
                statut=actif
            elif ((vu_actif)); then
                if [[ $point == inactif ]]; then
                    motif="point d'accès arrêté"
                else
                    motif="état du point d'accès incertain"
                fi
            elif profil_absent; then
                # Activation abandonnée. Liste illisible : rien n'est conclu.
                motif="profil temporaire supprimé"
            elif ((maintenant - debut_attente >= WH_DELAI_ACTIVATION)); then
                motif="point d'accès non activé dans le délai"
            fi
        fi
        [[ -n $motif ]] || ecrire_etat "$statut" presente ""
    done
    arret_securise "$motif"
}

cmd_apres_arret() {
    lire_options "--wifi --uuid --session" -- "$@"
    exiger WIFI UUID WH_SESSION
    exiger_root

    local session statut table motif code=0
    session=$(wh_lire_cle "$WH_RUN/etat" session)
    statut=$(wh_lire_cle "$WH_RUN/etat" statut)
    table=$(wh_lire_cle "$WH_RUN/etat" table)
    motif=$(wh_lire_cle "$WH_RUN/etat" motif)
    if [[ $session != "$WH_SESSION" || $statut != arrete || $table != absente ]]; then
        [[ $session == "$WH_SESSION" && -n $motif ]] || motif="arrêt du service de garde"
        arret_securise "$motif" || code=$?
    fi
    ((code == 0)) && supprimer_copies
    return "$code"
}

# Retire les copies installées dans /run, une fois la table supprimée.
supprimer_copies() {
    rm -f "$WH_RUN/wansview-garde.sh" "$WH_RUN/lib/commun.sh" "$WH_RUN/lib/regles.sh"
    rmdir "$WH_RUN/lib" 2>/dev/null || true
}

cmd_nettoyer() {
    (($# == 0)) || wh_fatal "$WH_E_USAGE" "« nettoyer » n'accepte aucune option."
    exiger_root
    systemctl is-active --quiet "$WH_UNITE" &&
        wh_fatal "$WH_E_OCCUPE" "Le service de garde est actif : arrêtez-le d'abord."
    local interfaces
    interfaces=$(iw dev) || wh_fatal "$WH_E_ISOLATION" "État du Wi-Fi inconnu : rien n'est supprimé."
    [[ $interfaces != *$'\ttype AP'* ]] ||
        wh_fatal "$WH_E_ISOLATION" "Un point d'accès est actif : rien n'est supprimé."
    local profils
    profils=$(nmcli -t -f UUID,NAME connection show) ||
        wh_fatal "$WH_E_ISOLATION" "Profils NetworkManager illisibles : rien n'est supprimé."
    [[ $profils$'\n' != *":$WH_NOM_PROFIL"$'\n'* ]] ||
        wh_fatal "$WH_E_ISOLATION" "Le profil temporaire existe encore : les règles sont conservées."
    wh_supprimer_table || exit
    supprimer_copies
    wh_info "Aucune table du projet ne subsiste."
}

main() {
    local commande=${1:-}
    (($#)) && shift
    case $commande in
        surveiller) cmd_surveiller "$@" ;;
        apres-arret) cmd_apres_arret "$@" ;;
        nettoyer) cmd_nettoyer "$@" ;;
        regles)
            lire_options "--wifi --eth --sous-reseau" -- "$@"
            exiger WIFI ETH
            wh_regles "$WIFI" "$ETH" "${SOUS_RESEAUX[@]}"
            ;;
        empreinte)
            (($# == 0)) || wh_fatal "$WH_E_USAGE" "« empreinte » n'accepte aucune option."
            exiger_root
            wh_empreinte
            ;;
        *) wh_fatal "$WH_E_USAGE" "Sous-commande inconnue." ;;
    esac
}

main "$@"
