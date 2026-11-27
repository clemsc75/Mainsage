#!/usr/bin/env bash
# Profil NetworkManager temporaire, activation du point d'accès et état du Wi-Fi.
# shellcheck disable=SC2153  # les constantes WH_* viennent de lib/commun.sh

# Toutes les propriétés du profil sont définies ici (un futur mode d'isolation
# des clients ajouterait « 802-11-wireless.ap-isolation »).
wh_proprietes_profil() { # <uuid> <wifi> <ssid> <canal> : remplit WH_PROFIL
    WH_PROFIL=(
        save no
        type wifi
        ifname "$2"
        con-name "$WH_NOM_PROFIL"
        connection.uuid "$1"
        autoconnect no
        ssid "$3"
        802-11-wireless.mode ap
        802-11-wireless.band bg
        802-11-wireless.channel "$4"
        802-11-wireless-security.key-mgmt wpa-psk
        802-11-wireless-security.proto rsn
        802-11-wireless-security.pairwise ccmp
        802-11-wireless-security.group ccmp
        802-11-wireless-security.pmf 1 # 1 = désactivé, pour la caméra
        802-11-wireless-security.psk-flags 2 # secret jamais enregistré
        ipv4.method shared
        ipv4.addresses "$WH_IP_AP/$WH_PREFIXE_AP"
        ipv4.shared-dhcp-range "$WH_DHCP_DEBUT,$WH_DHCP_FIN"
        ipv6.method disabled
    )
}

wh_creer_profil() { # <uuid> <wifi> <ssid> <canal>
    local sortie
    wh_proprietes_profil "$@"
    sortie=$(nmcli connection add "${WH_PROFIL[@]}" 2>&1) && return 0
    wh_erreur "Création du profil impossible : $(wh_assainir "$sortie")"
    return "$WH_E_PROFIL"
}

# Affiche les UUID des profils portant le nom du projet.
wh_profils_du_projet() {
    local liste uuid nom
    liste=$(nmcli -t -f UUID,NAME connection show) || return 1
    while IFS=: read -r uuid nom; do
        [[ $nom == "$WH_NOM_PROFIL" ]] && wh_valider_uuid "$uuid" && echo "$uuid"
    done <<<"$liste"
    return 0
}

# En cas de doute (NetworkManager muet), le profil est réputé exister.
wh_profil_existe() {
    local liste
    liste=$(nmcli -t -f UUID,NAME connection show 2>/dev/null) || return 0
    [[ $'\n'"$liste" == *$'\n'"$1:"* ]]
}

wh_supprimer_profil() { # <uuid>
    nmcli --wait 15 connection down uuid "$1" >/dev/null 2>&1
    nmcli --wait 15 connection delete uuid "$1" >/dev/null 2>&1
    ! wh_profil_existe "$1"
}

# Liste (nom, taille, date) des fichiers de configuration permanente.
wh_lister_configuration_permanente() {
    local dossier dossiers=() liste
    for dossier in "$WH_ETC/netplan" "$WH_ETC/NetworkManager/system-connections"; do
        [[ -d $dossier ]] && dossiers+=("$dossier")
    done
    ((${#dossiers[@]})) || return 1
    liste=$(find "${dossiers[@]}" -mindepth 1 -printf '%p %s %T@\n') || return 1
    [[ -z $liste ]] || LC_ALL=C sort <<<"$liste"
}

# Échoue si quelque chose a été écrit dans /etc ou si le profil n'est pas en mémoire.
wh_verifier_non_persistance() { # <uuid> <instantané de référence>
    local actuel liste uuid fichier trouve=""
    actuel=$(wh_lister_configuration_permanente) || {
        wh_erreur "Configuration permanente illisible sous /etc."
        return "$WH_E_PERSISTANCE"
    }
    if [[ $actuel != "$(<"$2")" ]]; then
        wh_erreur "Une écriture a été détectée dans /etc/netplan ou" \
            "/etc/NetworkManager/system-connections. Vérifiez ces dossiers."
        return "$WH_E_PERSISTANCE"
    fi
    liste=$(nmcli -t -f UUID,FILENAME connection show) || return "$WH_E_PERSISTANCE"
    while IFS=: read -r uuid fichier; do
        [[ $uuid == "$1" ]] && trouve=$fichier
    done <<<"$liste"
    # Les profils Netplan sont aussi sous /run : leur nom les trahit.
    if [[ $trouve != /run/NetworkManager/system-connections/* || ${trouve##*/} == netplan-* ]]; then
        wh_erreur "Le profil temporaire n'est pas purement en mémoire : $(wh_assainir "${trouve:-introuvable}")"
        return "$WH_E_PERSISTANCE"
    fi
}

# Le mot de passe passe uniquement par un tube : ni argument, ni fichier.
wh_activer_point_acces() { # <uuid> <mot de passe>
    local sortie
    sortie=$(printf '802-11-wireless-security.psk:%s\n' "$2" |
        nmcli --wait 30 connection up uuid "$1" passwd-file /dev/stdin 2>&1) && return 0
    wh_erreur "Activation du point d'accès impossible : $(wh_assainir "${sortie//"$2"/***}")"
    return "$WH_E_ACTIVATION"
}

wh_point_acces_actif() { # <wifi> <uuid>
    local infos courant
    infos=$(iw dev "$1" info 2>/dev/null) || return 1
    courant=$(nmcli -g GENERAL.CON-UUID device show "$1" 2>/dev/null) || return 1
    [[ $infos == *$'\ttype AP'* && $courant == "$2" ]]
}

wh_adresse_point_acces() { # <wifi>
    local adresses
    adresses=$(ip -4 -o addr show dev "$1") || return 1
    [[ $adresses == *" inet $WH_IP_AP/$WH_PREFIXE_AP "* ]]
}

# Libère la carte et empêche NetworkManager de la reconnecter entre-temps.
wh_liberer_wifi() { # <wifi> <radio initiale>
    local info i
    nmcli device set "$1" autoconnect no >/dev/null || return "$WH_E_ACTIVATION"
    if [[ $2 == disabled ]]; then
        nmcli radio wifi on >/dev/null || {
            wh_erreur "Impossible d'activer la radio Wi-Fi."
            return "$WH_E_ACTIVATION"
        }
    fi
    for ((i = 0; i < 50; i++)); do
        info=$(wh_peripherique "$1") || return "$WH_E_ACTIVATION"
        [[ ${info#*:} != unavailable ]] && break
        sleep 0.2 9>&-
    done
    case ${info#*:} in
        disconnected) return 0 ;;
        unavailable) wh_erreur "La carte $1 reste indisponible." ;;
        *)
            nmcli --wait 15 device disconnect "$1" >/dev/null && return 0
            wh_erreur "Impossible de déconnecter $1."
            ;;
    esac
    return "$WH_E_ACTIVATION"
}

# Remet la radio, la connexion et la reconnexion automatique comme avant.
wh_restaurer_wifi() { # <wifi> <radio initiale> <uuid initial> <autoconnect initial>
    local echec=0
    if [[ $2 == enabled ]]; then
        nmcli radio wifi on >/dev/null 2>&1 || echec=1
        if [[ -n $3 ]] && ! nmcli --wait 30 connection up uuid "$3" ifname "$1" >/dev/null 2>&1; then
            wh_alerte "La reconnexion au réseau Wi-Fi initial a échoué (hors de portée ?)." \
                "Reconnectez-le depuis les paramètres."
        fi
        nmcli device set "$1" autoconnect "$4" >/dev/null 2>&1 || echec=1
    else
        nmcli device set "$1" autoconnect "$4" >/dev/null 2>&1 || echec=1
        nmcli radio wifi off >/dev/null 2>&1 || echec=1
    fi
    ((!echec)) || wh_alerte "L'état initial du Wi-Fi n'a pas été entièrement rétabli."
}
