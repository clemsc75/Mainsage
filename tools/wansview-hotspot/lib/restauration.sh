#!/usr/bin/env bash
# Restauration idempotente et reprise après un arrêt brutal.

# Routes permanentes : tout sauf celles du Wi-Fi utilisé.
wh_routes_hors_wifi() { # <wifi>
    local routes
    routes=$(ip -4 route show) || return 1
    # « linkdown » varie avec l'état du câble des ponts virtuels : ignoré.
    awk -v dev="$1" '{
        for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == dev) next
        sub(/ linkdown *$/, "")
        print
    }' <<<"$routes" | LC_ALL=C sort
}

# Contrôles finaux : ils informent, sans bloquer la restauration.
wh_controler_apres_restauration() {
    local eth=${WH_ETAT[eth]} info uuid
    info=$(wh_peripherique "$eth")
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$eth" 2>/dev/null)
    if [[ ${info#*:} == connected && $uuid == "${WH_ETAT[uuid_eth]}" &&
        $(wh_iface_route_internet) == "$eth" ]]; then
        wh_info "Ethernet $eth : connectée, route Internet inchangée."
    else
        wh_alerte "L'Ethernet $eth n'est pas dans son état initial (câble ?). Le script ne l'a pas modifiée."
    fi
    if [[ -r $WH_DIR/routes-avant &&
        $(wh_routes_hors_wifi "${WH_ETAT[wifi]}") != "$(<"$WH_DIR/routes-avant")" ]]; then
        wh_alerte "Les routes (hors Wi-Fi) diffèrent de celles du démarrage."
    fi
    if [[ -r $WH_DIR/etc-avant &&
        $(wh_lister_configuration_permanente) != "$(<"$WH_DIR/etc-avant")" ]]; then
        wh_alerte "La liste des fichiers de /etc/netplan ou" \
            "/etc/NetworkManager/system-connections a changé depuis le démarrage."
    fi
}

# Nécessite WH_ETAT chargé. Conserve l'état tant qu'un reste dangereux subsiste.
wh_restaurer() {
    local echecs=0
    wh_info "Arrêt et restauration en cours..."

    if ! wh_supprimer_profil "${WH_ETAT[uuid_ap]}"; then
        wh_erreur "Le profil temporaire n'a pas pu être supprimé."
        echecs=1
    fi

    if [[ ${WH_ETAT[garde_lancee]} == 1 ]]; then
        if ! wh_arreter_garde; then
            wh_erreur "Le service de garde est toujours actif."
            echecs=1
        elif ! wh_assurer_table_retiree "${WH_ETAT[session]}"; then
            wh_erreur "La table nftables du projet n'a pas pu être retirée."
            echecs=1
        fi
    fi

    if [[ ${WH_ETAT[wifi_modifie]} == 1 ]]; then
        wh_restaurer_wifi "${WH_ETAT[wifi]}" "${WH_ETAT[radio_initiale]}" \
            "${WH_ETAT[uuid_initial]}" "${WH_ETAT[autoconnect_initial]}"
    fi

    wh_controler_apres_restauration

    if ((echecs)); then
        wh_erreur "Restauration incomplète. Relancez : wansview-hotspot.sh stop"
        return "$WH_E_RESTAURATION"
    fi
    wh_etat_supprimer
    wh_info "Restauration terminée."
}

# Restes sans fichier d'état (session perdue) : profil, service ou table.
wh_nettoyer_orphelins() {
    local profils uuid trouve=0 echecs=0 table
    profils=$(wh_profils_du_projet) || {
        wh_erreur "Liste des profils NetworkManager illisible."
        return "$WH_E_RESTAURATION"
    }
    for uuid in $profils; do
        trouve=1
        wh_info "Suppression d'un profil temporaire orphelin."
        wh_supprimer_profil "$uuid" || echecs=1
    done
    if wh_garde_actif; then
        trouve=1
        wh_info "Arrêt d'un service de garde orphelin (sudo)."
        sudo systemctl stop "$WH_UNITE" 9>&-
        wh_garde_actif && echecs=1
    fi
    table=$(wh_lire_cle "$WH_RUN/etat" table)
    if [[ $table != absente && (-n $table || $trouve -eq 1) ]]; then
        trouve=1
        wh_nettoyer_table || echecs=1
    fi
    if ((echecs)); then
        wh_erreur "Des restes subsistent : voir les messages ci-dessus."
        return "$WH_E_RESTAURATION"
    fi
    if ((trouve)); then
        wh_info "Restes supprimés."
    else
        wh_info "Rien à arrêter."
    fi
}
