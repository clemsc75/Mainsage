#!/usr/bin/env bash
# wansview-garde.sh : pose de l'isolation, surveillance et arrêt sécurisé.
# shellcheck disable=SC2016

UUID_AP=33333333-3333-4333-8333-333333333333
SESSION=44444444-4444-4444-8444-444444444444

preparer() {
    GARDE_SCRIPT="$RACINE_OUTIL/wansview-garde.sh"
    mkdir -p "$BAC/run/wansview-hotspot"
    faux_connexion "$UUID_AP" wansview-hotspot-tmp /run/NetworkManager/system-connections/x
    echo ap >"$FAUX/conn/$UUID_AP/mode"
    # Le Wi-Fi a été déconnecté par le script principal.
    faux_peripherique "$IFACE_WIFI" wifi disconnected
    # Processus qui joue le rôle du script principal.
    sleep 60 &
    PRINCIPAL=$!
    echo "$PRINCIPAL" >"$BAC/principal.pid"
    DEBUT=$(awk '{print $22}' "/proc/$PRINCIPAL/stat")
}

arguments_surveiller() {
    ARGS=(surveiller --wifi "$IFACE_WIFI" --eth "$IFACE_ETH" --uuid "$UUID_AP"
        --pid "$PRINCIPAL" --debut "$DEBUT" --session "$SESSION")
}

lancer_garde() {
    arguments_surveiller
    bac_exec bash "$GARDE_SCRIPT" "${ARGS[@]}" >"$BAC/garde.log" 2>&1 &
    GARDE=$!
    echo "$GARDE" >"$BAC/garde.pid"
}

etat() { sed -n "s/^$1=//p" "$BAC/run/wansview-hotspot/etat" 2>/dev/null; }
etat_est() { [[ $(etat "$1") == "$2" ]]; }

activer_ap() {
    echo connected >"$FAUX/dev/$IFACE_WIFI/state"
    echo "$UUID_AP" >"$FAUX/dev/$IFACE_WIFI/uuid"
    echo AP >"$FAUX/dev/$IFACE_WIFI/iwtype"
}

garde_en_service() {
    preparer
    lancer_garde
    attendre "isolation confirmée" etat_est statut pret
    activer_ap
    attendre "point d'accès vu" etat_est statut actif
}

# fin_garde <code attendu> <extrait du motif>
fin_garde() {
    attendre "arrêt du garde" bash -c "! kill -0 $GARDE 2>/dev/null || grep -q '^[0-9]* ([^)]*) Z' /proc/$GARDE/stat"
    wait "$GARDE"
    egal "$1" "$?" "code du garde : $(cat "$BAC/garde.log")"
    contient "$(etat motif)" "$2"
}

arret_complet() {
    egal arrete "$(etat statut)"
    egal absente "$(etat table)"
    absent "$FAUX/nft/projet"
    absent "$FAUX/conn/$UUID_AP"
    egal managed "$(faux_lire "dev/$IFACE_WIFI/iwtype")"
    egal "table inet existante" "$(faux_lire nft/autres)"
}

test_refuse_sans_root() {
    preparer
    arguments_surveiller
    executer bac_env env WH_MODE_TEST=0 bash "$GARDE_SCRIPT" "${ARGS[@]}"
    egal 4 "$CODE"
    egal "" "$(appels)"
}

test_chemin_fixe_hors_mode_test() {
    preparer
    rm "$BAC/bin/dirname"
    printf '#!%s\n: >"%s/pwn"\n' "$BAC/bin/bash" "$BAC" >"$BAC/bin/dirname"
    chmod +x "$BAC/bin/dirname"
    executer bac_env env WH_MODE_TEST=0 bash "$GARDE_SCRIPT" regles \
        --wifi "$IFACE_WIFI" --eth "$IFACE_ETH"
    egal 0 "$CODE" "$SORTIE"
    absent "$BAC/pwn"
}

test_arguments_invalides() {
    preparer
    local option valeur
    for option in --wifi --eth --uuid --pid --debut --session; do
        arguments_surveiller
        valeur="a[\$(touch $BAC/pwn)]"
        local i
        for i in "${!ARGS[@]}"; do
            [[ ${ARGS[i]} == "$option" ]] && ARGS[i + 1]=$valeur
        done
        executer bac_env bash "$GARDE_SCRIPT" "${ARGS[@]}"
        egal 2 "$CODE" "$option"
    done
    executer bac_env bash "$GARDE_SCRIPT" surveiller --wifi "$IFACE_WIFI"
    egal 2 "$CODE" "options manquantes"
    executer bac_env bash "$GARDE_SCRIPT" inconnue
    egal 2 "$CODE"
    executer bac_env bash "$GARDE_SCRIPT" regles --wifi "$IFACE_WIFI" --eth "$IFACE_ETH" --autre x
    egal 2 "$CODE"
    absent "$BAC/pwn"
    egal "" "$(appels)"
}

test_sous_commande_regles() {
    preparer
    executer bac_env bash "$GARDE_SCRIPT" regles --wifi "$IFACE_WIFI" --eth "$IFACE_ETH" \
        --sous-reseau 12.0.0.0/24
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" 12.0.0.0/24
    egal "" "$(appels)"
}

test_isolation_posee_avec_les_reseaux_ethernet() {
    preparer
    echo "12.1.0.0/16 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    lancer_garde
    attendre "isolation confirmée" etat_est statut pret
    egal presente "$(etat table)"
    egal "$SESSION" "$(etat session)"
    contient "$(faux_lire nft/projet)" 12.1.0.0/16
    egal 644 "$(stat -c %a "$BAC/run/wansview-hotspot/etat")"
}

test_arret_quand_le_processus_principal_disparait() {
    garde_en_service
    kill -KILL "$PRINCIPAL"
    fin_garde 0 "processus principal"
    arret_complet
}

test_numero_de_processus_reutilise() {
    preparer
    DEBUT=1
    arguments_surveiller
    executer bac_env bash "$GARDE_SCRIPT" "${ARGS[@]}"
    egal 8 "$CODE"
    absent "$FAUX/nft/projet"
}

test_arret_quand_le_point_d_acces_est_coupe() {
    garde_en_service
    rm -r "${FAUX:?}/conn/$UUID_AP"
    faux_peripherique "$IFACE_WIFI" wifi disconnected
    fin_garde 0 "point d'accès arrêté"
    arret_complet
}

test_arret_si_le_point_d_acces_n_est_jamais_active() {
    preparer
    DELAI_ACTIVATION=1 lancer_garde
    fin_garde 0 "délai"
    arret_complet
}

test_arret_si_la_table_est_alteree() {
    garde_en_service
    sed -i "/chain input {/a\\		accept" "$FAUX/nft/projet"
    fin_garde 0 "règles"
    arret_complet
    # L'isolation a été rétablie avant la coupure du point d'accès.
    local pose coupure
    pose=$(grep -n '^nft -f -' "$FAUX/appels.log" | tail -1 | cut -d: -f1)
    coupure=$(grep -n '^nmcli .*connection down' "$FAUX/appels.log" | head -1 | cut -d: -f1)
    egal 2 "$(grep -c '^nft -f -' "$FAUX/appels.log")"
    ((pose < coupure)) || echec "les règles doivent être rétablies avant la coupure"
}

test_arret_si_la_table_est_supprimee() {
    garde_en_service
    rm "$FAUX/nft/projet"
    fin_garde 0 "règles"
    arret_complet
}

test_remplissage_dynamique_tolere() {
    garde_en_service
    sed -i '/set decouverte_wsd {/a\		elements = { 40000 }' "$FAUX/nft/projet"
    sleep 0.6
    egal actif "$(etat statut)"
    kill -0 "$GARDE" || echec "le garde doit rester actif"
}

test_arret_si_les_reseaux_ethernet_changent() {
    garde_en_service
    echo "12.2.0.0/16 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    fin_garde 0 "Ethernet"
    arret_complet
}

test_arret_sur_signal() {
    garde_en_service
    kill -TERM "$GARDE"
    fin_garde 0 "signal"
    arret_complet
}

test_table_conservee_si_la_coupure_echoue() {
    garde_en_service
    faux_echec down
    faux_echec delete
    kill -KILL "$PRINCIPAL"
    fin_garde 8 "processus principal"
    egal conservee "$(etat table)"
    existe "$FAUX/nft/projet"
}

test_table_conservee_si_le_profil_reste() {
    garde_en_service
    faux_echec delete
    kill -KILL "$PRINCIPAL"
    fin_garde 8 "processus principal"
    egal conservee "$(etat table)"
    existe "$FAUX/nft/projet"
}

test_table_conservee_en_cas_de_doute() {
    garde_en_service
    faux_echec iw
    fin_garde 8 "point d'accès"
    egal conservee "$(etat table)"
    existe "$FAUX/nft/projet"
}

test_echec_de_nftables() {
    preparer
    faux_echec nft
    arguments_surveiller
    executer bac_env bash "$GARDE_SCRIPT" "${ARGS[@]}"
    egal 8 "$CODE"
    egal erreur "$(etat statut)"
}

test_table_etrangere_refusee() {
    preparer
    printf 'table inet wansview_hotspot {\n}\n' >"$FAUX/nft/projet"
    arguments_surveiller
    executer bac_env bash "$GARDE_SCRIPT" "${ARGS[@]}"
    egal 8 "$CODE"
    existe "$FAUX/nft/projet"
    ne_contient "$(appels)" "nft -f"
    ne_contient "$(appels)" "nft delete"
}

apres_arret() {
    executer bac_env bash "$GARDE_SCRIPT" apres-arret --wifi "$IFACE_WIFI" --uuid "$UUID_AP" \
        --session "$SESSION"
}

test_apres_arret_brutal_du_garde() {
    garde_en_service
    kill -KILL "$GARDE"
    wait "$GARDE" 2>/dev/null
    mkdir -p "$BAC/run/wansview-hotspot/lib"
    : >"$BAC/run/wansview-hotspot/wansview-garde.sh"
    : >"$BAC/run/wansview-hotspot/lib/commun.sh"
    apres_arret
    egal 0 "$CODE" "$SORTIE"
    arret_complet
    absent "$BAC/run/wansview-hotspot/wansview-garde.sh"
    absent "$BAC/run/wansview-hotspot/lib/commun.sh"
    existe "$RACINE_OUTIL/lib/commun.sh"
}

test_apres_arret_sans_effet_si_deja_arrete() {
    garde_en_service
    kill -TERM "$GARDE"
    fin_garde 0 "signal"
    : >"$FAUX/appels.log"
    apres_arret
    egal 0 "$CODE" "$SORTIE"
    ne_contient "$(appels)" "connection down"
    contient "$(etat motif)" "signal"
}

test_nettoyer_supprime_la_table_orpheline() {
    preparer
    rm -r "${FAUX:?}/conn/$UUID_AP"
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 0 "$CODE" "$SORTIE"
    absent "$FAUX/nft/projet"
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 0 "$CODE" "$SORTIE"
}

test_nettoyer_refuse_si_un_point_d_acces_est_actif() {
    preparer
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    activer_ap
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 8 "$CODE"
    existe "$FAUX/nft/projet"
}

test_nettoyer_refuse_si_le_profil_temporaire_existe() {
    preparer
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 8 "$CODE" "$SORTIE"
    existe "$FAUX/nft/projet"
}

test_nettoyer_refuse_une_table_etrangere() {
    preparer
    printf 'table inet wansview_hotspot {\n}\n' >"$FAUX/nft/projet"
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 8 "$CODE"
    existe "$FAUX/nft/projet"
}

test_nettoyer_refuse_si_le_garde_tourne() {
    preparer
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    : >"$FAUX/unit/wansview-hotspot-garde.actif"
    executer bac_env bash "$GARDE_SCRIPT" nettoyer
    egal 5 "$CODE"
    existe "$FAUX/nft/projet"
}
