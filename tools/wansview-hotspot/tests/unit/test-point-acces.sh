#!/usr/bin/env bash
# lib/point-acces.sh : cas non couverts par les tests de bout en bout.
# shellcheck disable=SC2016  # le code testé est développé par le bash enfant

test_suppression_confirmee() {
    reussit 'wh_supprimer_profil "$1"' "$UUID_INITIAL"
    absent "$FAUX/conn/$UUID_INITIAL"
    reussit 'wh_supprimer_profil "$1"' "$UUID_INITIAL"
}

test_suppression_non_confirmee_si_networkmanager_muet() {
    faux_echec delete
    faux_echec liste_profils
    refuse 'wh_supprimer_profil "$1"' "$UUID_INITIAL"
}

test_ecriture_dans_etc_detectee() {
    reussit 'wh_lister_configuration_permanente >"$WH_BAC/avant"
             : >"$WH_ETC/netplan/nouveau.yaml"
             ! wh_verifier_non_persistance "$1" "$WH_BAC/avant"' "$UUID_INITIAL"
    contient "$SORTIE" "/etc/netplan"
}

test_modification_d_un_fichier_detectee() {
    reussit 'wh_lister_configuration_permanente >"$WH_BAC/avant"
             echo "ajout" >>"$WH_ETC/netplan/00-installer.yaml"
             [[ $(wh_lister_configuration_permanente) != "$(<"$WH_BAC/avant")" ]]'
}
