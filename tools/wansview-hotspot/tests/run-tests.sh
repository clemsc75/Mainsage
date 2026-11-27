#!/usr/bin/env bash
# Lance les tests unitaires. Aucun droit particulier, aucun accès au réseau réel.
# Usage : tests/run-tests.sh [motif]
set -u

TESTS=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RACINE=$(dirname "$TESTS")
MOTIF=${1:-}

if [[ $EUID -eq 0 ]]; then
    echo "Les tests ne doivent pas être lancés en root." >&2
    exit 1
fi

reussis=0
echoues=0

for fichier in "$TESTS"/unit/test-*.sh; do
    [[ -f $fichier ]] || continue
    nom_fichier=$(basename "$fichier")
    fonctions=$(bash -c 'source "$1"; source "$2"; compgen -A function test_' _ \
        "$TESTS/aide.sh" "$fichier")
    for fonction in $fonctions; do
        [[ -z $MOTIF || "$nom_fichier $fonction" == *"$MOTIF"* ]] || continue
        sortie=$(bash -c '
            source "$1"; source "$2"
            bac_creer
            trap bac_detruire EXIT
            bac_verifier
            bac_scenario_defaut
            "$3"
        ' _ "$TESTS/aide.sh" "$fichier" "$fonction" 2>&1)
        code=$?
        if [[ $code -eq 0 ]]; then
            reussis=$((reussis + 1))
        else
            echoues=$((echoues + 1))
            printf '✗ %s : %s (code %s)\n%s\n\n' "$nom_fichier" "$fonction" "$code" "$sortie"
        fi
    done
done

printf 'Tests Bash : %s réussis, %s échoués\n' "$reussis" "$echoues"
statut=0
[[ $echoues -eq 0 && $reussis -gt 0 ]] || statut=1

if [[ -z $MOTIF ]]; then
    if compgen -G "$TESTS/unit/test_*.py" >/dev/null; then
        echo "Tests Python :"
        python3 -B -m unittest discover -s "$TESTS/unit" -p 'test_*.py' || statut=1
    fi

    mapfile -t scripts < <(find "$RACINE" -type f \( -name '*.sh' -o -path '*/tests/faux/*' \) | sort)
    for script in "${scripts[@]}"; do
        bash -n "$script" || statut=1
    done
    printf 'bash -n : %s fichiers vérifiés\n' "${#scripts[@]}"

    if command -v shellcheck >/dev/null; then
        if (cd "$RACINE" && shellcheck -x "${scripts[@]}"); then
            echo "ShellCheck : aucune remarque"
        else
            statut=1
        fi
    else
        echo "ShellCheck absent : analyse non effectuée."
    fi
fi

exit "$statut"
