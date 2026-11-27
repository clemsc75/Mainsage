#!/usr/bin/env bash
# Côté utilisateur du garde : installation, lancement, santé et nettoyage.
# Les seules commandes lancées avec sudo sont ici.

WH_FICHIERS_GARDE=(wansview-garde.sh lib/commun.sh lib/regles.sh)

wh_sommes_garde() { # <répertoire>
    (cd "$1" && sha256sum "${WH_FICHIERS_GARDE[@]}")
}

# Copie le garde dans /run, hors de portée de l'utilisateur, puis compare les
# empreintes avec celles calculées avant la demande de mot de passe sudo.
wh_installer_garde() {
    local attendu obtenu fichier mode
    attendu=$(wh_sommes_garde "$WH_RACINE") || return "$WH_E_ISOLATION"
    wh_info "Droits administrateur nécessaires pour installer l'isolation (sudo)."
    sudo install -d -o root -g root -m 0755 "$WH_RUN" "$WH_RUN/lib" 9>&- || {
        wh_erreur "Installation du garde refusée ou impossible."
        return "$WH_E_ISOLATION"
    }
    for fichier in "${WH_FICHIERS_GARDE[@]}"; do
        mode=0644
        [[ $fichier == wansview-garde.sh ]] && mode=0755
        sudo install -o root -g root -m "$mode" "$WH_RACINE/$fichier" "$WH_RUN/$fichier" 9>&- ||
            return "$WH_E_ISOLATION"
    done
    obtenu=$(wh_sommes_garde "$WH_RUN") || return "$WH_E_ISOLATION"
    if [[ $obtenu != "$attendu" ]]; then
        wh_erreur "Les fichiers installés diffèrent des fichiers vérifiés : abandon."
        return "$WH_E_ISOLATION"
    fi
}

wh_lancer_garde() { # <wifi> <eth> <uuid> <session>
    local garde="$WH_RUN/wansview-garde.sh" debut
    debut=$(wh_debut_processus $$) || return "$WH_E_ISOLATION"
    sudo systemd-run --unit="$WH_UNITE" --collect --quiet \
        --description="Garde du point d'accès Wansview" \
        --property=NoNewPrivileges=yes \
        --property=ProtectHome=yes \
        --property=ProtectSystem=strict \
        --property=ReadWritePaths=/run \
        --property=PrivateTmp=yes \
        --property=CapabilityBoundingSet=CAP_NET_ADMIN \
        --property=ExecStopPost="$garde apres-arret --wifi $1 --uuid $3 --session $4" \
        -- "$garde" surveiller --wifi "$1" --eth "$2" --uuid "$3" \
        --pid "$$" --debut "$debut" --session "$4" 9>&- && return 0
    wh_erreur "Le service de garde n'a pas pu être lancé."
    return "$WH_E_ISOLATION"
}

wh_garde_actif() { systemctl is-active --quiet "$WH_UNITE"; }

# Champ du signal de vie, seulement s'il concerne la session demandée.
wh_signal_garde() { # <session> <clé>
    [[ $(wh_lire_cle "$WH_RUN/etat" session) == "$1" ]] || return 1
    wh_lire_cle "$WH_RUN/etat" "$2"
}

# Âge en secondes du signal de vie.
wh_age_signal() { # <session>
    local instant maintenant
    instant=$(wh_signal_garde "$1" uptime) && wh_valider_entier "$instant" || return 1
    maintenant=$(wh_uptime) || return 1
    echo "$((maintenant - instant))"
}

# Service actif, isolation déclarée et signal de vie récent.
wh_garde_sain() { # <session>
    local statut age
    wh_garde_actif || return 1
    statut=$(wh_signal_garde "$1" statut) || return 1
    [[ $statut == pret || $statut == actif ]] || return 1
    age=$(wh_age_signal "$1") || return 1
    ((age <= WH_AGE_MAX))
}

wh_attendre_garde() { # <session> : isolation confirmée ou échec
    local limite
    limite=$(($(wh_uptime) + WH_DELAI_GARDE))
    while (($(wh_uptime) <= limite)); do
        wh_garde_sain "$1" && return 0
        wh_garde_actif || break
        [[ $(wh_signal_garde "$1" statut) == erreur ]] && break
        sleep 0.2 9>&-
    done
    wh_erreur "Isolation non confirmée : $(wh_motif_garde "$1"). Le point d'accès n'est pas démarré."
    return "$WH_E_ISOLATION"
}

wh_motif_garde() { # <session>
    local motif
    motif=$(wh_signal_garde "$1" motif) || motif=""
    wh_assainir "${motif:-raison inconnue (voir : journalctl -u $WH_UNITE)}"
}

wh_attendre_arret_garde() {
    local limite
    limite=$(($(wh_uptime) + WH_DELAI_ARRET))
    while wh_garde_actif; do
        (($(wh_uptime) <= limite)) || return 1
        sleep 0.2 9>&-
    done
}

wh_arreter_garde() {
    wh_attendre_arret_garde && return 0
    wh_alerte "Le garde ne s'arrête pas seul : arrêt du service (sudo)."
    sudo systemctl stop "$WH_UNITE" 9>&-
    ! wh_garde_actif
}

# Supprime une table restée en place (le garde refuse si un point d'accès émet).
wh_nettoyer_table() {
    wh_installer_garde || return
    sudo "$WH_RUN/wansview-garde.sh" nettoyer 9>&-
}

wh_assurer_table_retiree() { # <session>
    [[ $(wh_signal_garde "$1" table) == absente ]] && return 0
    wh_nettoyer_table
}
