#!/usr/bin/env bash
# lib/commun.sh : validation des entrées, adresses IPv4, processus, fichiers.
# shellcheck disable=SC2016  # le code testé est développé par le bash enfant

test_interfaces_valides() {
    local v
    for v in wlp2s0 enp1s0f0 wlan0 eth0.12 br-1a2b3c4d5e6f; do
        reussit 'wh_valider_iface "$1"' "$v"
    done
}

test_interfaces_refusees() {
    local v
    for v in '' '-x' 'wlan0;ls' '$(id)' 'a b' 'interface-beaucoup-trop-longue' '../x' $'a\nb'; do
        refuse 'wh_valider_iface "$1"' "$v"
    done
}

test_uuid_et_pid() {
    reussit 'wh_valider_uuid "$1"' "$UUID_INITIAL"
    refuse 'wh_valider_uuid "$1"' "${UUID_INITIAL}x"
    reussit 'wh_valider_pid 4242'
    refuse 'wh_valider_pid 0'
    refuse 'wh_valider_pid "$1"' '12; ls'
    refuse 'wh_valider_pid "$1"' '-1'
}

test_canal() {
    local v
    for v in 1 6 11 13 14; do reussit 'wh_valider_canal "$1"' "$v"; done
    for v in 0 15 36 06 6a '' ' 6'; do refuse 'wh_valider_canal "$1"' "$v"; done
}

test_aucune_evaluation_arithmetique_des_entrees() {
    refuse 'wh_valider_canal "$1"' "a[\$(touch $BAC/pwn)]"
    refuse 'wh_valider_pid "$1"' "a[\$(touch $BAC/pwn)]"
    refuse 'wh_valider_cidr "$1"' "10.0.0.0/a[\$(touch $BAC/pwn)]"
    absent "$BAC/pwn"
}

test_ssid() {
    reussit 'wh_valider_ssid Wansview-Setup'
    reussit 'wh_valider_ssid "$1"' 'Cam salon_2.4'
    local v
    for v in '' '-option' ' debut' 'fin ' 'a;b' 'a=b' 'abcdefghijklmnopqrstuvwxyz1234567' $'a\nb'; do
        refuse 'wh_valider_ssid "$1"' "$v"
    done
}

test_mot_de_passe_valide() {
    reussit 'wh_valider_mot_de_passe "$1"' "$MDP"
    reussit 'wh_valider_mot_de_passe "$1"' 'a b;c$d"e'"'"
    reussit 'wh_valider_mot_de_passe "$(printf "a%.0s" {1..63})"'
}

test_mot_de_passe_refuse() {
    refuse 'wh_valider_mot_de_passe 1234567'
    refuse 'wh_valider_mot_de_passe "$(printf "a%.0s" {1..64})"'
    refuse 'wh_valider_mot_de_passe "$1"' " $MDP"
    refuse 'wh_valider_mot_de_passe "$1"' "$MDP "
    refuse 'wh_valider_mot_de_passe "$1"' "$MDP\\"
    refuse 'wh_valider_mot_de_passe "$1"' "${MDP}é"
    refuse 'wh_valider_mot_de_passe "$1"' "$MDP"$'\t'
}

test_mot_de_passe_jamais_repete_dans_les_messages() {
    avec_libs 'wh_valider_mot_de_passe "$1"' " $MDP"
    ne_contient "$SORTIE" "$MDP"
}

test_assainir_garde_les_accents_et_retire_les_controles() {
    reussit 'wh_assainir "$1"' $'règles modifiées \e[31m\a\n\xc2\x9b fin'
    contient "$SORTIE" "règles modifiées ?[31m??? fin"
}

test_cidr() {
    reussit 'wh_valider_cidr 192.168.1.0/24'
    reussit 'wh_valider_cidr 10.0.0.1/32'
    local v
    for v in 0.0.0.0/0 10.0.0.0 10.0.0.256/8 10.0.0/8 10.0.0.0/33 '10.0.0.0/8, 1' ''; do
        refuse 'wh_valider_cidr "$1"' "$v"
    done
}

test_adresse_reseau() {
    reussit 'wh_cidr_reseau 172.20.21.13/24'
    egal 172.20.21.0/24 "$SORTIE"
    reussit 'wh_cidr_reseau 10.08.009.7/16'
    egal 10.8.0.0/16 "$SORTIE"
}

test_chevauchement() {
    reussit 'wh_cidr_chevauche 10.42.0.0/24 10.0.0.0/8'
    reussit 'wh_cidr_chevauche 10.42.0.0/24 10.42.0.7/32'
    refuse 'wh_cidr_chevauche 10.42.0.0/24 10.43.0.0/24'
    refuse 'wh_cidr_chevauche 10.42.0.0/24 192.168.0.0/16'
}

test_sous_reseaux_d_une_interface() {
    echo "203.0.113.128/25 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    echo "198.51.100.9 via 192.168.50.1 dev $IFACE_ETH" >>"$FAUX/ip/routes"
    reussit 'wh_sous_reseaux "$1"' "$IFACE_ETH"
    egal $'192.168.50.0/24\n198.51.100.9/32\n203.0.113.128/25' "$SORTIE"
}

test_processus_vivant_et_disparu() {
    reussit 'd=$(wh_debut_processus $$) && wh_processus_vivant $$ "$d"'
    refuse 'wh_processus_vivant $$ 1'
    reussit 'sleep 0.05 & p=$!; d=$(wh_debut_processus $p) || exit 1; wait $p
             ! wh_processus_vivant $p "$d"'
}

test_ecriture_atomique_et_lecture_sans_source() {
    reussit 'printf "a=1\nb=\$(touch %s)\n" "$WH_BAC/pwn" | wh_ecrire_atomique "$WH_BAC/f" 0600
             wh_lire_cle "$WH_BAC/f" b'
    contient "$SORTIE" '$(touch'
    absent "$BAC/pwn"
    egal 600 "$(stat -c %a "$BAC/f")"
    refuse 'wh_lire_cle "$WH_BAC/f" absente'
}

test_surcharges_ignorees_hors_mode_test() {
    executer bac_env env WH_MODE_TEST=0 bash -c \
        'source "$1/lib/commun.sh"; wh_configurer; echo "$WH_ETC $WH_RUN $WH_INTERVALLE"' \
        _ "$RACINE_OUTIL"
    egal "/etc /run/wansview-hotspot 2" "$SORTIE"
}

test_journal_structure_sans_saut_de_ligne() {
    reussit 'WH_JOURNAL="$WH_BAC/journal"; WH_SESSION=abc; wh_journal INFO "$1"' \
        $'ligne1\nniveau=ERREUR "x"'
    egal 1 "$(wc -l <"$BAC/journal")"
    contient "$(cat "$BAC/journal")" 'niveau=INFO session=abc message="ligne1 niveau=ERREUR'
}
