#!/usr/bin/env bash
# lib/regles.sh : contenu de la table nftables. La syntaxe et l'effet réels sont
# vérifiés par tests/isolation-netns.sh, lancé à la main avec les droits root.
# shellcheck disable=SC2016  # le code testé est développé par le bash enfant

regles() {
    reussit 'wh_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH" "$@"
}

# chaine <nom> : lignes d'une chaîne des dernières règles générées
chaine() { sed -n "/chain $1 {/,/^\t}/p" <<<"$SORTIE"; }

test_table_identifiable() {
    regles
    contient "$SORTIE" 'table inet wansview_hotspot {'
    contient "$SORTIE" 'comment "wansview-hotspot"'
}

test_ne_touche_a_aucune_autre_table() {
    regles
    ne_contient "$SORTIE" flush
    local autres
    autres=$(grep -E '^(add |delete |destroy )?table ' <<<"$SORTIE" | grep -v 'inet wansview_hotspot')
    egal "" "$autres"
}

test_priorite_avant_le_filtrage_habituel() {
    regles
    egal 3 "$(grep -c 'priority filter - 10; policy accept;' <<<"$SORTIE")"
}

test_reseaux_interdits() {
    regles 203.0.113.64/26 12.34.56.0/24
    local r
    for r in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 \
        192.168.0.0/16 224.0.0.0/4 240.0.0.0/4 12.34.56.0/24; do
        contient "$SORTIE" "$r"
    done
}

test_entree_depuis_le_wifi() {
    regles
    local c
    c=$(chaine input)
    contient "$c" "iifname != \"$IFACE_WIFI\" return"
    contient "$c" "meta nfproto ipv6 counter drop"
    contient "$c" "ct state established,related accept"
    contient "$c" "udp sport 68 udp dport 67 accept"
    contient "$c" "ip daddr 10.42.0.1 udp dport 53 accept"
    contient "$c" "ip daddr 10.42.0.1 tcp dport 53 accept"
    contient "$c" "ip daddr 10.42.0.1 udp dport @decouverte_wsd accept"
    # Rien d'autre n'est accepté, et le refus final vient en dernier.
    egal 5 "$(grep -c ' accept$' <<<"$c")"
    egal "counter drop" "$(grep -v '}' <<<"$c" | tail -1 | tr -d '\t')"
    # L'IPv6 est refusé avant toute acceptation.
    egal "meta nfproto ipv6 counter drop" "$(sed -n '4p' <<<"$c" | tr -d '\t')"
}

test_transfert_depuis_et_vers_le_wifi() {
    regles
    local attendu
    attendu="iifname \"$IFACE_WIFI\" meta nfproto ipv6 counter drop
iifname \"$IFACE_WIFI\" ip saddr != 10.42.0.0/24 counter drop
iifname \"$IFACE_WIFI\" oifname != \"$IFACE_ETH\" counter drop
iifname \"$IFACE_WIFI\" ip daddr @interdits counter drop
iifname \"$IFACE_WIFI\" accept
oifname \"$IFACE_WIFI\" iifname \"$IFACE_ETH\" meta nfproto ipv4 ct state established,related accept
oifname \"$IFACE_WIFI\" counter drop"
    egal "$attendu" "$(chaine forward | grep 'name' | tr -d '\t')"
}

test_sortie_du_pc_jamais_bloquee() {
    regles
    local c
    c=$(chaine output)
    ne_contient "$c" drop
    ne_contient "$c" reject
    contient "$c" "oifname \"$IFACE_WIFI\" ip daddr 239.255.255.250 udp dport 3702 update @decouverte_wsd { udp sport }"
}

test_ensemble_de_decouverte_temporaire() {
    regles
    contient "$SORTIE" "flags dynamic,timeout"
    contient "$SORTIE" "timeout 10s"
    contient "$SORTIE" "size 64"
}

test_arguments_dangereux_refuses() {
    refuse 'wh_regles "$@"' 'wl"; drop' "$IFACE_ETH"
    refuse 'wh_regles "$@"' "$IFACE_WIFI" 'e }'
    refuse 'wh_regles "$@"' "$IFACE_WIFI" "$IFACE_WIFI"
    refuse 'wh_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH" 0.0.0.0/0
    refuse 'wh_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH" '10.0.0.0/8 }'
}

test_pose_et_suppression() {
    reussit 'wh_poser_regles "$@" && wh_etat_table' "$IFACE_WIFI" "$IFACE_ETH"
    egal nous "$SORTIE"
    reussit 'wh_supprimer_table && wh_etat_table'
    egal absente "$SORTIE"
    reussit wh_supprimer_table
    egal "table inet existante" "$(faux_lire nft/autres)"
}

test_table_etrangere_jamais_touchee() {
    printf 'table inet wansview_hotspot {\n}\n' >"$FAUX/nft/projet"
    reussit wh_etat_table
    egal etrangere "$SORTIE"
    refuse 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    refuse wh_supprimer_table
    existe "$FAUX/nft/projet"
    ne_contient "$(appels)" "nft -f"
    ne_contient "$(appels)" "nft delete"
}

test_etat_inconnu_si_nft_echoue() {
    faux_echec nft_liste
    refuse wh_etat_table
    refuse wh_empreinte
}

test_empreinte_stable_et_sensible() {
    reussit 'wh_poser_regles "$@" && wh_empreinte' "$IFACE_WIFI" "$IFACE_ETH"
    local reference=$SORTIE
    # Le remplissage de l'ensemble dynamique n'est pas une altération.
    sed -i '/set decouverte_wsd {/a\		elements = { 40000 }' "$FAUX/nft/projet"
    echo 1 >"$FAUX/nft/compteur"
    reussit wh_empreinte
    egal "$reference" "$SORTIE" "compteur à la suite de la taille"
    echo 2 >"$FAUX/nft/compteur"
    reussit wh_empreinte
    egal "$reference" "$SORTIE" "compteur modifié"
    rm "$FAUX/nft/compteur"
    sed -i '/set decouverte_wsd {/a\		# count 1' "$FAUX/nft/projet"
    reussit wh_empreinte
    egal "$reference" "$SORTIE" "compteur seul sur sa ligne"
    sed -i 's/10\.0\.0\.0\/8, //' "$FAUX/nft/projet"
    reussit wh_empreinte
    [[ $SORTIE != "$reference" ]] || echec "un ensemble « interdits » modifié doit changer l'empreinte"
}

test_empreinte_sensible_a_une_taille_modifiee() {
    reussit 'wh_poser_regles "$@" && wh_empreinte' "$IFACE_WIFI" "$IFACE_ETH"
    local reference=$SORTIE
    sed -i 's/size 64$/size 65535/' "$FAUX/nft/projet"
    echo 1 >"$FAUX/nft/compteur"
    reussit wh_empreinte
    [[ $SORTIE != "$reference" ]] || echec "une taille modifiée doit changer l'empreinte"
}

test_un_commentaire_ne_masque_pas_une_regle() {
    reussit 'wh_poser_regles "$@" && wh_empreinte' "$IFACE_WIFI" "$IFACE_ETH"
    local reference=$SORTIE
    sed -i '/chain input {/a\		accept comment "# count 1"' "$FAUX/nft/projet"
    reussit wh_empreinte
    [[ $SORTIE != "$reference" ]] || echec "une règle commentée doit changer l'empreinte"
}

test_empreinte_sensible_a_une_regle_ajoutee() {
    reussit 'wh_poser_regles "$@" && wh_empreinte' "$IFACE_WIFI" "$IFACE_ETH"
    local reference=$SORTIE
    sed -i "/chain input {/a\\		iifname \"$IFACE_WIFI\" accept" "$FAUX/nft/projet"
    reussit wh_empreinte
    [[ $SORTIE != "$reference" ]] || echec "une règle ajoutée doit changer l'empreinte"
}
