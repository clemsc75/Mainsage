#!/usr/bin/env bash
# Le bac à sable lui-même : aucune vraie commande réseau accessible.

test_commandes_reseau_toutes_simulees() {
    local c
    for c in "${COMMANDES_SIMULEES[@]}"; do
        executer bac_env bash -c "readlink -f \"\$(command -v $c)\""
        egal "$RACINE_FAUX/$c" "$SORTIE" "$c doit être simulé"
    done
}

test_path_limite_au_bac() {
    # shellcheck disable=SC2016  # développé par le bash enfant
    executer bac_env bash -c 'echo "$PATH"; command -v rfkill wpa_cli ufw iptables; true'
    egal "$BAC/bin" "$SORTIE"
}

test_sudo_simule_refuse_un_chemin_reel() {
    executer bac_env sudo /usr/bin/true
    egal 98 "$CODE"
}

test_install_simule_refuse_hors_bac() {
    executer bac_env install -m 0644 /etc/hostname /tmp/wh-interdit
    egal 98 "$CODE"
}

test_fausse_commande_refuse_hors_bac() {
    executer env -i PATH="$BAC/bin" "$RACINE_FAUX/nmcli" radio wifi
    egal 99 "$CODE"
}

test_scenario_par_defaut_lisible() {
    executer bac_env nmcli -t -f DEVICE,TYPE,STATE device
    contient "$SORTIE" "$IFACE_ETH:ethernet:connected"
    contient "$SORTIE" "$IFACE_WIFI:wifi:connected"
}
