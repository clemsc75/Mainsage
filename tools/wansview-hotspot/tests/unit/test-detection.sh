#!/usr/bin/env bash
# lib/detection.sh : vérifications faites avant toute modification.
# shellcheck disable=SC2016  # le code testé est développé par le bash enfant

aucune_modification() {
    ne_contient "$(appels)" "connection add"
    ne_contient "$(appels)" "radio wifi on"
    ne_contient "$(appels)" "device disconnect"
    ne_contient "$(appels)" "sudo"
}

test_scenario_valide() {
    reussit 'wh_verifier_dependances && wh_verifier_nm && wh_verifier_permissions &&
             wh_choisir_ethernet "" && wh_choisir_wifi "" 6 && wh_verifier_conflit_routes "$1"' \
        "$IFACE_WIFI"
    egal "$IFACE_ETH"$'\n'"$IFACE_WIFI" "$SORTIE"
    aucune_modification
}

test_valide_sous_pipefail() {
    reussit 'set -o pipefail; wh_choisir_ethernet "" && wh_choisir_wifi "" 6'
    egal "$IFACE_ETH"$'\n'"$IFACE_WIFI" "$SORTIE"
}

test_dependance_absente() {
    rm "$BAC/bin/dnsmasq"
    refuse wh_verifier_dependances
    contient "$SORTIE" dnsmasq
}

test_networkmanager_inactif() {
    : >"$FAUX/nm/running"
    refuse wh_verifier_nm
}

test_permission_refusee() {
    sed -i 's/network-control:yes/network-control:no/' "$FAUX/nm/permissions"
    refuse wh_verifier_permissions
    contient "$SORTIE" network-control
}

test_pas_d_ethernet() {
    echo unavailable >"$FAUX/dev/$IFACE_ETH/state"
    refuse 'wh_choisir_ethernet ""'
    contient "$SORTIE" "Aucune connexion Ethernet active"
}

test_route_par_un_vpn() {
    echo "1.1.1.1 dev tailscale0 table 52 src 100.64.0.3 uid 1000" >"$FAUX/ip/route_get"
    refuse 'wh_choisir_ethernet ""'
    contient "$SORTIE" tailscale0
}

test_route_par_le_wifi() {
    echo "1.1.1.1 via 172.20.36.254 dev $IFACE_WIFI src 172.20.36.44" >"$FAUX/ip/route_get"
    refuse 'wh_choisir_ethernet ""'
    contient "$SORTIE" "$IFACE_WIFI"
}

test_aucune_route_internet() {
    : >"$FAUX/ip/route_get"
    refuse 'wh_choisir_ethernet ""'
}

test_plusieurs_cartes_ethernet() {
    faux_peripherique enx001122 ethernet connected "" 192.168.60.2/24
    reussit 'wh_choisir_ethernet ""'
    egal "$IFACE_ETH" "$SORTIE" "la carte qui porte la route Internet"
    refuse 'wh_choisir_ethernet enx001122'
}

test_interface_ethernet_demandee_invalide() {
    refuse 'wh_choisir_ethernet inconnue0'
    refuse 'wh_choisir_ethernet "$1"' "$IFACE_WIFI"
    refuse 'wh_choisir_ethernet "$1"' 'a;b'
}

test_wifi_non_gere() {
    echo unmanaged >"$FAUX/dev/$IFACE_WIFI/state"
    refuse 'wh_choisir_wifi "" 6'
    contient "$SORTIE" NetworkManager
}

test_pas_de_wifi() {
    rm -r "${FAUX:?}/dev/$IFACE_WIFI"
    refuse 'wh_choisir_wifi "" 6'
}

test_mode_ap_non_pris_en_charge() {
    sed -i '/\* AP$/d' "$FAUX/phy/phy0"
    refuse 'wh_choisir_wifi "" 6'
    contient "$SORTIE" "point d'accès"
}

test_bande_2_4_ghz_absente() {
    sed -i '/\* 24/d' "$FAUX/phy/phy0"
    refuse 'wh_choisir_wifi "" 6'
}

test_canaux_utilisables() {
    sed -i 's/\(\[11\].*\)$/\1 (radar detection)/' "$FAUX/phy/phy0"
    reussit 'wh_canaux_utilisables phy0'
    egal "1 2 3 4 5 6 7 8 9 10" "$SORTIE"
}

test_canal_12_refuse() {
    refuse 'wh_choisir_wifi "" 12'
    contient "$SORTIE" "Canal 12"
}

test_blocage_materiel() {
    echo 1 >"$BAC/sys/class/net/$IFACE_WIFI/phy80211/rfkill0/hard"
    refuse 'wh_choisir_wifi "" 6'
    contient "$SORTIE" matériel
}

test_radio_desactivee_acceptee() {
    echo disabled >"$FAUX/nm/radio"
    reussit 'wh_choisir_wifi "" 6'
}

test_deux_cartes_wifi_utilisables() {
    faux_peripherique wlan1 wifi disconnected
    faux_wifi wlan1 phy1
    faux_phy phy1
    refuse 'wh_choisir_wifi "" 6'
    contient "$SORTIE" "--wifi-iface"
    reussit 'wh_choisir_wifi wlan1 6'
    egal wlan1 "$SORTIE"
}

test_seconde_carte_sans_mode_ap_ignoree() {
    faux_peripherique wlan1 wifi disconnected
    faux_wifi wlan1 phy1
    faux_phy phy1
    sed -i '/\* AP$/d' "$FAUX/phy/phy1"
    reussit 'wh_choisir_wifi "" 6'
    egal "$IFACE_WIFI" "$SORTIE"
}

test_conflit_de_route() {
    echo "10.0.0.0/8 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    refuse 'wh_verifier_conflit_routes "$1"' "$IFACE_WIFI"
    contient "$SORTIE" 10.0.0.0/8
}

test_conflit_d_adresse() {
    faux_peripherique virbr9 bridge "connected (externally)" "" 10.42.0.200/24
    refuse 'wh_verifier_conflit_routes "$1"' "$IFACE_WIFI"
}

test_route_du_wifi_remplace_ignoree() {
    echo "10.42.0.0/24 dev $IFACE_WIFI proto kernel scope link" >>"$FAUX/ip/routes"
    echo "local 10.42.0.57 dev $IFACE_WIFI table local proto kernel" >>"$FAUX/ip/routes"
    reussit 'wh_verifier_conflit_routes "$1"' "$IFACE_WIFI"
}
