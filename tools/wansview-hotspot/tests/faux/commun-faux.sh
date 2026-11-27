#!/usr/bin/env bash
# Base commune des fausses commandes. Refuse de fonctionner hors d'un bac à sable.
set -u

if [[ -z ${WH_FAUX:-} || -z ${WH_BAC:-} || ! -d ${WH_FAUX:-/nonexistent} ]]; then
    echo "fausse commande lancée hors du bac à sable" >&2
    exit 99
fi

F=$WH_FAUX

journaliser() { printf '%s\n' "$*" >>"$F/appels.log"; }
en_echec() { [[ -e $F/echec/$1 ]]; }
lire() { cat "$1" 2>/dev/null; }

non_simule() {
    echo "appel non simulé : $*" >&2
    printf 'NON SIMULÉ : %s\n' "$*" >>"$F/appels.log"
    exit 98
}
