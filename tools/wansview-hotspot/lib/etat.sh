#!/usr/bin/env bash
# État de session du script principal : répertoire privé, verrou, journal.
# Le fichier d'état est relu clé par clé et validé ; il n'est jamais exécuté.
# shellcheck disable=SC2034  # WH_JOURNAL et WH_SESSION servent à lib/commun.sh

declare -A WH_ETAT=()

WH_CLES_ETAT=(session wifi eth uuid_ap ssid canal uuid_initial radio_initiale
    autoconnect_initial uuid_eth garde_lancee wifi_modifie actif)

wh_preparer_repertoires() {
    local runtime=${XDG_RUNTIME_DIR:-}
    if [[ $runtime != /* || ! -d $runtime || ! -O $runtime ]]; then
        wh_erreur "XDG_RUNTIME_DIR absent ou invalide : lancez le script depuis votre session."
        return "$WH_E_PREREQUIS"
    fi
    WH_DIR="$runtime/wansview-hotspot"
    wh_repertoire_prive "$WH_DIR" || return

    local base=${XDG_STATE_HOME:-${HOME:-}/.local/state}
    [[ $base == /* ]] || return "$WH_E_PREREQUIS"
    wh_repertoire_prive "$base/wansview-hotspot" || return
    WH_JOURNAL="$base/wansview-hotspot/journal.log"
}

wh_repertoire_prive() {
    if [[ -L $1 ]] || ! mkdir -p "$1" || [[ ! -O $1 ]] || ! chmod 700 "$1"; then
        wh_erreur "Répertoire privé inutilisable : $1"
        return "$WH_E_PREREQUIS"
    fi
}

# Verrou exclusif sur le descripteur 9, libéré à la fin du processus.
wh_verrouiller() { # [secondes d'attente]
    exec 9<>"$WH_DIR/verrou" || return 1
    if [[ -n ${1:-} ]]; then
        flock -w "$1" 9 || return 1
    else
        flock -n 9 || return 1
    fi
    printf 'pid=%s\ndebut=%s\n' "$$" "$(wh_debut_processus $$)" >"$WH_DIR/verrou"
}

wh_etat_present() { [[ -e $WH_DIR/etat ]]; }

wh_etat_valeur_valide() { # <clé> <valeur>
    case $1 in
        session | uuid_ap | uuid_eth) wh_valider_uuid "$2" ;;
        uuid_initial) [[ -z $2 ]] || wh_valider_uuid "$2" ;;
        wifi | eth) wh_valider_iface "$2" ;;
        ssid) wh_valider_ssid "$2" ;;
        canal) wh_valider_canal "$2" ;;
        radio_initiale) [[ $2 == enabled || $2 == disabled ]] ;;
        autoconnect_initial) [[ $2 == yes || $2 == no ]] ;;
        garde_lancee | wifi_modifie | actif) [[ $2 == 0 || $2 == 1 ]] ;;
        *) return 1 ;;
    esac
}

wh_etat_enregistrer() {
    local cle contenu=""
    for cle in "${WH_CLES_ETAT[@]}"; do
        contenu+="$cle=${WH_ETAT[$cle]:-}"$'\n'
    done
    printf '%s' "$contenu" | wh_ecrire_atomique "$WH_DIR/etat" 0600
}

wh_etat_definir() { # <clé> <valeur> : enregistre immédiatement
    WH_ETAT[$1]=$2
    wh_etat_enregistrer
}

wh_etat_charger() {
    local cle valeur
    WH_ETAT=()
    for cle in "${WH_CLES_ETAT[@]}"; do
        if ! valeur=$(wh_lire_cle "$WH_DIR/etat" "$cle") ||
            ! wh_etat_valeur_valide "$cle" "$valeur"; then
            wh_erreur "Fichier d'état invalide ($WH_DIR/etat, clé $cle). Rien n'est modifié."
            return "$WH_E_RESTAURATION"
        fi
        WH_ETAT[$cle]=$valeur
    done
    WH_SESSION=${WH_ETAT[session]}
}

wh_etat_supprimer() {
    rm -f "$WH_DIR/etat" "$WH_DIR/etc-avant" "$WH_DIR/routes-avant"
}

wh_nouvel_uuid() {
    local uuid
    read -r uuid </proc/sys/kernel/random/uuid && wh_valider_uuid "$uuid" && echo "$uuid"
}
