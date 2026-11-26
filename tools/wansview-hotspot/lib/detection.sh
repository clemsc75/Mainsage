#!/usr/bin/env bash
# Détection et vérifications préalables. Lecture seule : rien n'est modifié.
# Chaque fonction affiche la raison d'un refus et renvoie un code non nul.

WH_DEPENDANCES=(nmcli iw ip nft flock dnsmasq sudo systemd-run systemctl
    sha256sum install date mktemp find awk sort grep)

wh_verifier_dependances() {
    local commande manquantes=()
    for commande in "${WH_DEPENDANCES[@]}"; do
        command -v "$commande" >/dev/null 2>&1 || manquantes+=("$commande")
    done
    ((${#manquantes[@]} == 0)) && return 0
    wh_erreur "Commandes absentes : ${manquantes[*]}."
    wh_erreur "Paquets Ubuntu concernés : network-manager, iw, iproute2, nftables," \
        "dnsmasq-base, util-linux, systemd, sudo, coreutils. Rien n'est installé automatiquement."
    return "$WH_E_PREREQUIS"
}

wh_verifier_nm() {
    [[ $(nmcli -t -f RUNNING general 2>/dev/null) == running ]] && return 0
    wh_erreur "NetworkManager n'est pas actif."
    return "$WH_E_PREREQUIS"
}

wh_verifier_permissions() {
    local sortie permission
    sortie=$(nmcli -t general permissions) || {
        wh_erreur "Permissions NetworkManager illisibles."
        return "$WH_E_PREREQUIS"
    }
    for permission in network-control settings.modify.system wifi.share.protected enable-disable-wifi; do
        case $'\n'"$sortie"$'\n' in
            *$'\n'"org.freedesktop.NetworkManager.$permission:yes"$'\n'*) ;;
            *$'\n'"org.freedesktop.NetworkManager.$permission:auth"$'\n'*) ;;
            *)
                wh_erreur "Permission NetworkManager manquante : $permission."
                return "$WH_E_PREREQUIS"
                ;;
        esac
    done
}

# Liste « interface:type:état ».
wh_peripheriques() { nmcli -t -f DEVICE,TYPE,STATE device; }

# wh_peripherique <interface> : affiche « type:état »
wh_peripherique() {
    local liste nom type etat
    liste=$(wh_peripheriques) || return 1
    while IFS=: read -r nom type etat; do
        if [[ $nom == "$1" ]]; then
            echo "$type:$etat"
            return 0
        fi
    done <<<"$liste"
    return 1
}

# Connexion gérée par NetworkManager, même si sa connectivité est jugée limitée
# (portail captif, par exemple). « connected (externally) » est exclu.
wh_etat_connecte() {
    [[ $1 == connected || $1 == "connected (local only)" || $1 == "connected (site only)" ]]
}

wh_ethernet_active() { # <liste de wh_peripheriques>
    local nom type etat
    while IFS=: read -r nom type etat; do
        [[ $type == ethernet ]] && wh_etat_connecte "$etat" && return 0
    done <<<"$1"
    return 1
}

wh_iface_route_internet() {
    local sortie mots i
    sortie=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
    read -r -a mots <<<"$sortie"
    for ((i = 0; i + 1 < ${#mots[@]}; i++)); do
        if [[ ${mots[i]} == dev ]]; then
            echo "${mots[i + 1]}"
            return 0
        fi
    done
    return 1
}

# wh_choisir_ethernet [interface demandée] : affiche l'interface retenue.
wh_choisir_ethernet() {
    local demande=$1 route info choisie liste
    if [[ -n $demande ]] && ! wh_valider_iface "$demande"; then
        wh_erreur "Nom d'interface Ethernet invalide."
        return "$WH_E_USAGE"
    fi
    liste=$(wh_peripheriques) || return "$WH_E_PREREQUIS"
    # Pas de « | grep -q » : sous pipefail, il ferait échouer la commande amont.
    if [[ -z $demande ]] && ! wh_ethernet_active "$liste"; then
        wh_erreur "Aucune connexion Ethernet active. Branchez le câble réseau."
        return "$WH_E_PREREQUIS"
    fi
    route=$(wh_iface_route_internet) || {
        wh_erreur "Aucune route vers Internet."
        return "$WH_E_PREREQUIS"
    }
    choisie=${demande:-$route}
    info=$(wh_peripherique "$choisie") || {
        wh_erreur "Interface $choisie inconnue de NetworkManager."
        return "$WH_E_PREREQUIS"
    }
    if [[ $demande && ${info%%:*} != ethernet ]]; then
        wh_erreur "$choisie n'est pas une interface Ethernet."
        return "$WH_E_PREREQUIS"
    fi
    if [[ ${info%%:*} != ethernet || $route != "$choisie" ]]; then
        wh_erreur "La route Internet passe par $(wh_assainir "$route") et non par l'Ethernet${demande:+ $demande}" \
            "(VPN actif ou câble absent ?)."
        return "$WH_E_PREREQUIS"
    fi
    if ! wh_etat_connecte "${info#*:}"; then
        wh_erreur "L'interface $choisie n'est pas connectée par NetworkManager."
        return "$WH_E_PREREQUIS"
    fi
    echo "$choisie"
}

wh_phy() { # <interface>
    local nom re='^[A-Za-z0-9_.-]+$'
    { read -r nom <"$WH_SYS/class/net/$1/phy80211/name"; } 2>/dev/null || return 1
    [[ $nom =~ $re ]] || return 1
    echo "$nom"
}

wh_ap_pris_en_charge() { # <phy>
    local infos ligne dans_la_liste=0
    infos=$(iw phy "$1" info) || return 1
    while IFS= read -r ligne; do
        ligne=${ligne#"${ligne%%[![:space:]]*}"}
        if [[ $ligne == "Supported interface modes:" ]]; then
            dans_la_liste=1
        elif ((dans_la_liste)); then
            [[ $ligne == "* AP" ]] && return 0
            [[ $ligne == "* "* ]] || dans_la_liste=0
        fi
    done <<<"$infos"
    return 1
}

# Canaux 2,4 GHz sur lesquels un point d'accès peut émettre.
wh_canaux_utilisables() { # <phy>
    local infos ligne canaux=() re='\* 24[0-9]{2}(\.[0-9]+)? MHz \[([0-9]+)\](.*)$'
    infos=$(iw phy "$1" info) || return 1
    while IFS= read -r ligne; do
        [[ $ligne =~ $re ]] || continue
        case ${BASH_REMATCH[3]} in
            *disabled* | *"no IR"* | *radar*) continue ;;
        esac
        canaux+=("${BASH_REMATCH[2]}")
    done <<<"$infos"
    ((${#canaux[@]})) || return 1
    echo "${canaux[*]}"
}

wh_blocage_materiel() { # <interface>
    local fichier valeur
    for fichier in "$WH_SYS/class/net/$1/phy80211"/rfkill*/hard; do
        [[ -r $fichier ]] || continue
        read -r valeur <"$fichier"
        [[ $valeur == 1 ]] && return 0
    done
    return 1
}

# Affiche la raison pour laquelle une carte Wi-Fi ne convient pas, sinon rien.
wh_defaut_wifi() { # <interface> <état NetworkManager> <canal>
    local phy canaux
    if [[ $2 == unmanaged ]]; then
        echo "$1 n'est pas gérée par NetworkManager."
    elif ! phy=$(wh_phy "$1"); then
        echo "$1 : matériel radio introuvable."
    elif ! wh_ap_pris_en_charge "$phy"; then
        echo "$1 ne prend pas en charge le mode point d'accès."
    elif ! canaux=$(wh_canaux_utilisables "$phy"); then
        echo "$1 n'a aucun canal 2,4 GHz utilisable."
    elif [[ " $canaux " != *" $3 "* ]]; then
        echo "Canal $3 non utilisable sur $1 (autorisés : $canaux)."
    elif wh_blocage_materiel "$1"; then
        echo "$1 est bloquée par un interrupteur matériel."
    fi
}

# wh_choisir_wifi <interface demandée ou vide> <canal> : affiche l'interface.
wh_choisir_wifi() {
    local demande=$1 canal=$2 liste nom type etat defaut valides=() defauts=()
    if [[ -n $demande ]] && ! wh_valider_iface "$demande"; then
        wh_erreur "Nom d'interface Wi-Fi invalide."
        return "$WH_E_USAGE"
    fi
    liste=$(wh_peripheriques) || return "$WH_E_PREREQUIS"
    while IFS=: read -r nom type etat; do
        [[ $type == wifi ]] || continue
        [[ -z $demande || $nom == "$demande" ]] || continue
        wh_valider_iface "$nom" || continue
        defaut=$(wh_defaut_wifi "$nom" "$etat" "$canal")
        if [[ -z $defaut ]]; then
            valides+=("$nom")
        else
            defauts+=("$defaut")
        fi
    done <<<"$liste"

    case ${#valides[@]} in
        1)
            echo "${valides[0]}"
            return 0
            ;;
        0)
            ((${#defauts[@]})) || defauts=("Aucune interface Wi-Fi${demande:+ nommée $demande}.")
            for defaut in "${defauts[@]}"; do wh_erreur "$defaut"; done
            ;;
        *) wh_erreur "Plusieurs cartes Wi-Fi conviennent (${valides[*]}) : précisez --wifi-iface." ;;
    esac
    return "$WH_E_PREREQUIS"
}

# Aucune autre interface ne doit utiliser le réseau du point d'accès. Le Wi-Fi
# choisi est ignoré : sa connexion actuelle va être remplacée.
wh_verifier_conflit_routes() { # <interface Wi-Fi>
    local routes adresses mots cible i
    routes=$(ip -4 route show table all) || return "$WH_E_PREREQUIS"
    adresses=$(ip -4 -o addr show) || return "$WH_E_PREREQUIS"
    while read -r -a mots; do
        ((${#mots[@]})) || continue
        [[ " ${mots[*]} " == *" dev $1 "* ]] && continue
        cible=${mots[0]}
        [[ $cible == [0-9]* || $cible == default ]] || cible=${mots[1]:-}
        [[ $cible == [0-9]* ]] || continue
        [[ $cible == */* ]] || cible+=/32
        wh_signaler_conflit "$cible" || return "$WH_E_PREREQUIS"
    done <<<"$routes"
    while read -r -a mots; do
        [[ ${mots[1]:-} == "$1" ]] && continue
        for ((i = 2; i + 1 < ${#mots[@]}; i++)); do
            [[ ${mots[i]} == inet ]] || continue
            wh_signaler_conflit "${mots[i + 1]}" || return "$WH_E_PREREQUIS"
        done
    done <<<"$adresses"
}

wh_signaler_conflit() { # <CIDR>
    wh_cidr_chevauche "$1" "$WH_RESEAU_AP" || return 0
    wh_erreur "Conflit : $1 chevauche le réseau du point d'accès $WH_RESEAU_AP."
    return 1
}
