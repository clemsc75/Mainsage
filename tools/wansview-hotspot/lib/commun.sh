#!/usr/bin/env bash
# Fonctions communes au script principal et au garde : constantes, codes
# d'erreur, validation des entrées, adresses IPv4, processus, fichiers, journal.
# Ce fichier est exécuté en root par le garde : aucune entrée n'y est évaluée.
# shellcheck disable=SC2034  # constantes utilisées par les fichiers qui l'incluent

WH_VERSION=0.1.0
WH_NOM_PROFIL=wansview-hotspot-tmp
WH_UNITE=wansview-hotspot-garde
WH_TABLE=wansview_hotspot
WH_COMMENTAIRE=wansview-hotspot
WH_IP_AP=10.42.0.1
WH_PREFIXE_AP=24
WH_RESEAU_AP=10.42.0.0/24
WH_DHCP_DEBUT=10.42.0.10
WH_DHCP_FIN=10.42.0.100
WH_SSID_DEFAUT=Wansview-Setup
WH_CANAL_DEFAUT=6

# Codes de sortie.
WH_E_USAGE=2        # option ou valeur invalide
WH_E_PREREQUIS=3    # condition de démarrage non remplie
WH_E_ROOT=4         # mauvais niveau de privilège
WH_E_OCCUPE=5       # déjà en cours, ou restes d'une session précédente
WH_E_PROFIL=6       # profil NetworkManager impossible à créer
WH_E_PERSISTANCE=7  # écriture dans la configuration permanente
WH_E_ISOLATION=8    # isolation impossible à garantir
WH_E_ACTIVATION=9   # point d'accès impossible à activer
WH_E_RESTAURATION=10 # restauration incomplète

# Les surcharges réservées aux tests ne sont jamais acceptées en root.
wh_mode_test() { [[ $EUID -ne 0 && ${WH_MODE_TEST:-} == 1 ]]; }

wh_configurer() {
    WH_ETC=/etc
    WH_SYS=/sys
    WH_RUN=/run/wansview-hotspot
    WH_INTERVALLE=2        # secondes entre deux contrôles
    WH_DELAI_GARDE=15      # attente maximale de la confirmation d'isolation
    WH_DELAI_ARRET=20      # attente maximale de l'arrêt du garde
    WH_DELAI_ACTIVATION=60 # délai laissé pour activer le point d'accès
    WH_AGE_MAX=6           # âge maximal du signal de vie du garde
    wh_mode_test || return 0
    WH_ETC=${WH_TEST_ETC:-$WH_ETC}
    WH_SYS=${WH_TEST_SYS:-$WH_SYS}
    WH_RUN=${WH_TEST_RUN:-$WH_RUN}
    WH_INTERVALLE=${WH_TEST_INTERVALLE:-$WH_INTERVALLE}
    WH_DELAI_GARDE=${WH_TEST_DELAI_GARDE:-$WH_DELAI_GARDE}
    WH_DELAI_ARRET=${WH_TEST_DELAI_ARRET:-$WH_DELAI_ARRET}
    WH_DELAI_ACTIVATION=${WH_TEST_DELAI_ACTIVATION:-$WH_DELAI_ACTIVATION}
    WH_AGE_MAX=${WH_TEST_AGE_MAX:-$WH_AGE_MAX}
}

# ------------------------------------------------------------------- messages

wh_journal() { # <niveau> <message> ; sans effet si WH_JOURNAL est vide
    [[ -n ${WH_JOURNAL:-} ]] || return 0
    local message=${2//[$'\n\r\t']/ }
    message=${message//\"/\'}
    printf 'date=%s niveau=%s session=%s message="%s"\n' \
        "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "${WH_SESSION:--}" "$message" \
        >>"$WH_JOURNAL" 2>/dev/null || true
}

# L'affichage ne doit jamais interrompre une restauration (terminal fermé).
wh_info() {
    printf '%s\n' "$*" 2>/dev/null || true
    wh_journal INFO "$*"
}

wh_alerte() {
    printf 'Attention : %s\n' "$*" >&2 2>/dev/null || true
    wh_journal ALERTE "$*"
}

wh_erreur() {
    printf 'Erreur : %s\n' "$*" >&2 2>/dev/null || true
    wh_journal ERREUR "$*"
}

wh_fatal() { # <code> <message>
    local code=$1
    shift
    wh_erreur "$*"
    exit "$code"
}

# Rend une valeur non fiable affichable : les caractères de contrôle sont
# remplacés (y compris C1 en UTF-8), les accents sont conservés.
wh_assainir() {
    local LC_ALL=C v=${1:0:200}
    v=${v//$'\xc2'[$'\x80'-$'\x9f']/?}
    printf '%s' "${v//[$'\x01'-$'\x1f'$'\x7f']/?}"
}

# ----------------------------------------------------------------- validation
# Toute valeur est validée par expression régulière avant le moindre calcul :
# (( )) et -lt évaluent leur contenu et pourraient exécuter du code.

wh_valider_iface() {
    local LC_ALL=C re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$'
    [[ $1 =~ $re ]]
}

wh_valider_uuid() {
    local LC_ALL=C re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    [[ $1 =~ $re ]]
}

wh_valider_entier() {
    local LC_ALL=C re='^(0|[1-9][0-9]{0,17})$'
    [[ $1 =~ $re ]]
}

wh_valider_pid() {
    local LC_ALL=C re='^[1-9][0-9]{0,9}$'
    [[ $1 =~ $re ]]
}

wh_valider_canal() {
    local re='^([1-9]|1[0-4])$'
    [[ $1 =~ $re ]]
}

wh_valider_ssid() {
    local LC_ALL=C re='^[A-Za-z0-9_]([A-Za-z0-9 _.-]{0,30}[A-Za-z0-9_.-])?$'
    [[ $1 =~ $re ]]
}

# 8 à 63 caractères ASCII imprimables. La barre oblique inverse est refusée :
# son interprétation par « nmcli ... passwd-file » est ambiguë.
# Les messages ne répètent jamais la valeur.
wh_valider_mot_de_passe() {
    local LC_ALL=C re='^[ -~]+$'
    if ((${#1} < 8 || ${#1} > 63)); then
        echo "Le mot de passe doit contenir de 8 à 63 caractères." >&2
    elif [[ ! $1 =~ $re ]]; then
        echo "Le mot de passe doit être en ASCII imprimable (sans accent)." >&2
    elif [[ $1 == ' '* || $1 == *' ' ]]; then
        echo "Le mot de passe ne doit ni commencer ni finir par une espace." >&2
    elif [[ $1 == *\\* ]]; then
        echo "La barre oblique inverse n'est pas acceptée dans le mot de passe." >&2
    else
        return 0
    fi
    return 1
}

# ------------------------------------------------------------- adresses IPv4

wh_ip_vers_entier() {
    local LC_ALL=C re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    [[ $1 =~ $re ]] || return 1
    local octets=("${BASH_REMATCH[@]:1}") octet n=0
    for octet in "${octets[@]}"; do
        octet=$((10#$octet))
        ((octet <= 255)) || return 1
        n=$((n * 256 + octet))
    done
    echo "$n"
}

wh_entier_vers_ip() {
    echo "$((($1 >> 24) & 255)).$((($1 >> 16) & 255)).$((($1 >> 8) & 255)).$(($1 & 255))"
}

# Préfixe de 1 à 32 : une route /0 couvrirait tout Internet.
wh_valider_cidr() {
    local re='^[0-9.]+/([1-9]|[12][0-9]|3[0-2])$'
    [[ $1 =~ $re ]] && wh_ip_vers_entier "${1%/*}" >/dev/null
}

wh_cidr_reseau() {
    wh_valider_cidr "$1" || return 1
    local n prefixe=${1#*/} masque
    n=$(wh_ip_vers_entier "${1%/*}") || return 1
    masque=$(((0xFFFFFFFF << (32 - prefixe)) & 0xFFFFFFFF))
    echo "$(wh_entier_vers_ip $((n & masque)))/$prefixe"
}

wh_cidr_chevauche() {
    wh_valider_cidr "$1" && wh_valider_cidr "$2" || return 1
    local prefixe=${1#*/}
    ((${2#*/} < prefixe)) && prefixe=${2#*/}
    [[ $(wh_cidr_reseau "${1%/*}/$prefixe") == "$(wh_cidr_reseau "${2%/*}/$prefixe")" ]]
}

# Sous-réseaux joignables par une interface (adresses et routes), un par ligne.
# Échoue au moindre doute : le résultat sert à construire le pare-feu.
wh_sous_reseaux() {
    local iface=$1 adresses routes ligne mot trouves=() i
    adresses=$(ip -4 -o addr show dev "$iface") || return 1
    routes=$(ip -4 route show dev "$iface") || return 1

    while read -r -a mot; do
        for ((i = 0; i + 1 < ${#mot[@]}; i++)); do
            [[ ${mot[i]} == inet || ${mot[i]} == peer ]] && trouves+=("${mot[i + 1]}")
        done
    done <<<"$adresses"

    while read -r -a mot; do
        ((${#mot[@]})) || continue
        ligne=${mot[0]}
        [[ $ligne == [0-9]* || $ligne == default ]] || ligne=${mot[1]:-}
        [[ $ligne == default || $ligne == 0.0.0.0/0 ]] && continue
        trouves+=("$ligne")
    done <<<"$routes"

    local resultat=""
    for ligne in "${trouves[@]}"; do
        [[ $ligne == */* ]] || ligne+=/32
        ligne=$(wh_cidr_reseau "$ligne") || return 1
        resultat+=$ligne$'\n'
    done
    [[ -n $resultat ]] || return 0
    printf '%s' "$resultat" | LC_ALL=C sort -u
}

# ------------------------------------------------------------------ processus

wh_uptime() {
    local secondes reste
    read -r secondes reste </proc/uptime || return 1
    echo "${secondes%%.*}"
}

# Heure de démarrage d'un processus vivant : avec le PID, elle l'identifie
# sans ambiguïté, même si le numéro est réutilisé.
wh_debut_processus() {
    wh_valider_pid "$1" || return 1
    local contenu champs
    { contenu=$(<"/proc/$1/stat"); } 2>/dev/null || return 1
    [[ -n $contenu ]] || return 1
    # Le nom du processus, entre parenthèses, peut contenir des espaces.
    read -r -a champs <<<"${contenu##*) }"
    [[ ${champs[0]} != [ZXx] ]] || return 1
    echo "${champs[19]}"
}

wh_processus_vivant() { # <pid> <début>
    local debut
    debut=$(wh_debut_processus "$1") && [[ $debut == "$2" ]]
}

# ------------------------------------------------------------------- fichiers

wh_ecrire_atomique() { # <fichier> <mode> ; contenu sur l'entrée standard
    local temporaire
    temporaire=$(mktemp "$1.XXXXXX") || return 1
    if cat >"$temporaire" && chmod "$2" "$temporaire" && mv -f "$temporaire" "$1"; then
        return 0
    fi
    rm -f "$temporaire"
    return 1
}

# Lit « clé=valeur » sans jamais exécuter ni inclure le fichier.
wh_lire_cle() { # <fichier> <clé>
    local ligne
    [[ -r $1 ]] || return 1
    while IFS= read -r ligne; do
        if [[ $ligne == "$2="* ]]; then
            printf '%s\n' "${ligne#*=}"
            return 0
        fi
    done <"$1"
    return 1
}
