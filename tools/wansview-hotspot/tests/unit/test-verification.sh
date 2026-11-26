#!/usr/bin/env bash
# tests/verification-reelle.sh (logique de comparaison, avec fausses commandes)
# et refus de sécurité de tests/isolation-netns.sh.
# shellcheck disable=SC2016

VERIFICATION="$RACINE_OUTIL/tests/verification-reelle.sh"

verifier() { executer bac_env bash "$VERIFICATION" "$@"; }

table_du_projet() {
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    : >"$FAUX/appels.log" # seuls les appels du script vérifié sont contrôlés
}

lecture_seule() {
    local motif
    for motif in "connection " "radio wifi o" "device disconnect" "device set" "nft -f" "nft delete"; do
        ne_contient "$(grep -v 'connection show' "$FAUX/appels.log")" "$motif"
    done
    egal "" "$(grep '^sudo' "$FAUX/appels.log" | grep -Ev '^sudo nft (-s )?list (ruleset|tables)$')"
    ne_contient "$(appels)" "NON SIMULÉ"
}

test_avant_puis_apres_identiques() {
    verifier avant
    egal 0 "$CODE" "$SORTIE"
    verifier apres
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" "OK"
    lecture_seule
}

test_apres_sans_avant() {
    verifier apres
    egal 2 "$CODE" "$SORTIE"
    contient "$SORTIE" "avant"
}

test_regle_systeme_modifiee() {
    verifier avant
    echo "table inet ajoutee" >>"$FAUX/nft/autres"
    verifier apres
    egal 1 "$CODE" "$SORTIE"
    contient "$SORTIE" "ÉCHEC"
    contient "$SORTIE" "nftables"
}

test_table_du_projet_restante() {
    verifier avant
    table_du_projet
    verifier apres
    egal 1 "$CODE" "$SORTIE"
}

test_route_permanente_modifiee() {
    verifier avant
    echo "10.9.0.0/16 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    verifier apres
    egal 1 "$CODE" "$SORTIE"
    contient "$SORTIE" "routes"
}

test_ecriture_dans_etc() {
    verifier avant
    : >"$BAC/etc/netplan/90-nouveau.yaml"
    verifier apres
    egal 1 "$CODE" "$SORTIE"
}

test_internet_indisponible() {
    verifier avant
    faux_echec ping
    verifier apres
    egal 1 "$CODE" "$SORTIE"
    contient "$SORTIE" "Internet"
}

test_pendant_avec_camera() {
    verifier avant
    table_du_projet
    echo "10.42.0.0/24 dev $IFACE_WIFI proto kernel scope link src 10.42.0.1" >>"$FAUX/ip/routes"
    mkdir -p "$FAUX/ports"
    : >"$FAUX/ports/554"
    : >"$FAUX/onvif_ok"
    verifier pendant --camera 10.42.0.23
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" "port 554 ouvert"
    contient "$SORTIE" "port 443 fermé"
    contient "$SORTIE" "téléphone"
    contient "$(appels)" "decouverte-onvif.py --source 10.42.0.1"
    lecture_seule
}

test_pendant_sans_isolation() {
    verifier avant
    verifier pendant
    egal 1 "$CODE" "$SORTIE"
}

test_arguments_invalides() {
    verifier
    egal 2 "$CODE"
    verifier ensuite
    egal 2 "$CODE"
    verifier pendant --camera "a[\$(touch $BAC/pwn)]"
    egal 2 "$CODE"
    absent "$BAC/pwn"
}

# Le test d'isolation modifie des interfaces et des règles : il doit refuser
# de démarrer ailleurs que dans un espace de noms réseau jetable.
test_isolation_refuse_hors_espace_de_noms() {
    executer bac_env bash "$RACINE_OUTIL/tests/isolation-netns.sh"
    egal 4 "$CODE" "$SORTIE"
    egal "" "$(appels)"
}
