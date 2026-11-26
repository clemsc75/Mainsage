#!/usr/bin/env bash
# wansview-hotspot.sh de bout en bout, avec les fausses commandes et le vrai
# garde lancé sans privilège par le faux systemd-run.
# shellcheck disable=SC2016,SC2034,SC2153  # variables partagées avec tests/aide.sh

PRINCIPAL_SH="$RACINE_OUTIL/wansview-hotspot.sh"
UNITE=wansview-hotspot-garde

# ------------------------------------------------------------------ pilotage

principal() { executer bac_env bash "$PRINCIPAL_SH" "$@"; }

# Lance « start » comme dans un terminal : son propre groupe, SIGINT actif.
demarrer() {
    set -m
    bac_exec bash "$PRINCIPAL_SH" start "$@" < <(printf '%s\n' "$MDP") >"$BAC/start.log" 2>&1 &
    PID_START=$!
    set +m
}

journal_start() { cat "$BAC/start.log"; }

termine() {
    local stat
    { stat=$(<"/proc/$1/stat"); } 2>/dev/null || return 0
    [[ ${stat##*) } == [ZX]* ]]
}

attendre_actif() {
    local i
    for ((i = 0; i < 200; i++)); do
        # Dernière ligne affichée une fois le démarrage terminé.
        grep -q "pour arrêter et restaurer" "$BAC/start.log" 2>/dev/null && return 0
        termine "$PID_START" && break
        sleep 0.05
    done
    echec "le point d'accès n'a pas démarré :"$'\n'"$(journal_start)"
}

# fin_start <code attendu>
fin_start() {
    attendre "fin de start : $(journal_start)" termine "$PID_START"
    wait "$PID_START"
    egal "$1" "$?" "code de start :"$'\n'"$(journal_start)"
}

en_service() {
    demarrer "$@"
    attendre_actif
}

# ---------------------------------------------------------------- constats

fichier_etat() { echo "$BAC/xdg/wansview-hotspot/etat"; }
service_arrete() { [[ ! -e $FAUX/unit/$UNITE.actif ]]; }
profil_temporaire() { grep -l '^wansview-hotspot-tmp$' "$FAUX"/conn/*/name 2>/dev/null; }

secret_absent() {
    local trouves
    trouves=$(grep -rlF -- "$MDP" "$BAC")
    egal "" "$trouves" "mot de passe retrouvé dans un fichier ou un journal"
}

aucune_modification() {
    local motif
    for motif in "connection add" "connection up" "connection down" "connection delete" \
        "radio wifi on" "radio wifi off" "device disconnect" "device set" sudo systemd-run; do
        ne_contient "$(appels)" "$motif" "modification interdite"
    done
    absent "$(fichier_etat)"
}

# Tout ce qui doit être vrai après un arrêt, quel que soit l'état initial.
rien_ne_reste() {
    egal "" "$(profil_temporaire)" "profil temporaire restant"
    absent "$FAUX/nft/projet"
    absent "$(fichier_etat)"
    attendre "service de garde arrêté" service_arrete
    egal "table inet existante" "$(faux_lire nft/autres)"
    egal "$UUID_ETHERNET" "$(faux_lire "dev/$IFACE_ETH/uuid")"
    egal connected "$(faux_lire "dev/$IFACE_ETH/state")"
    absent "$FAUX/nft/FLUSH"
    ne_contient "$(appels)" "NON SIMULÉ"
    ne_contient "$(appels)" "$IFACE_ETH autoconnect"
    ne_contient "$(appels)" "connection down uuid $UUID_ETHERNET"
    ne_contient "$(appels)" "connection delete uuid $UUID_ETHERNET"
    secret_absent
}

wifi_restaure() {
    rien_ne_reste
    egal "$UUID_INITIAL" "$(faux_lire "dev/$IFACE_WIFI/uuid")" "profil Wi-Fi initial"
    egal managed "$(faux_lire "dev/$IFACE_WIFI/iwtype")"
    egal yes "$(faux_lire "dev/$IFACE_WIFI/autoconnect")"
    egal enabled "$(faux_lire nm/radio)"
}

# ------------------------------------------------------------------ succès

test_demarrage_affiche_les_informations() {
    en_service
    local s
    s=$(journal_start)
    contient "$s" "Wansview-Setup"
    contient "$s" "10.42.0.1"
    contient "$s" "10.42.0.10 à 10.42.0.100"
    contient "$s" "$IFACE_ETH"
    contient "$s" "Isolation"
    existe "$FAUX/psk_conforme"
    existe "$FAUX/nft/projet"
    egal AP "$(faux_lire "dev/$IFACE_WIFI/iwtype")"
    secret_absent
}

test_profil_temporaire_conforme() {
    en_service
    local fichier proprietes attendu
    fichier=$(profil_temporaire)
    proprietes=$(<"${fichier%/name}/proprietes")
    for attendu in save=no type=wifi "ifname=$IFACE_WIFI" autoconnect=no ssid=Wansview-Setup \
        802-11-wireless.mode=ap 802-11-wireless.band=bg 802-11-wireless.channel=6 \
        802-11-wireless-security.key-mgmt=wpa-psk 802-11-wireless-security.proto=rsn \
        802-11-wireless-security.pairwise=ccmp 802-11-wireless-security.group=ccmp \
        802-11-wireless-security.pmf=1 802-11-wireless-security.psk-flags=2 \
        ipv4.method=shared ipv4.addresses=10.42.0.1/24 \
        ipv4.shared-dhcp-range=10.42.0.10,10.42.0.100 ipv6.method=disabled; do
        contient $'\n'"$proprietes"$'\n' $'\n'"$attendu"$'\n'
    done
    ne_contient "$proprietes" "psk=" "le mot de passe ne va pas dans le profil"
}

test_ordre_isolation_avant_activation() {
    en_service
    local pose activation sudo_ligne coupure
    sudo_ligne=$(grep -n '^sudo ' "$FAUX/appels.log" | head -1 | cut -d: -f1)
    coupure=$(grep -n '^nmcli .*device disconnect' "$FAUX/appels.log" | head -1 | cut -d: -f1)
    pose=$(grep -n '^nft -f -' "$FAUX/appels.log" | head -1 | cut -d: -f1)
    activation=$(grep -n 'passwd-file' "$FAUX/appels.log" | head -1 | cut -d: -f1)
    ((sudo_ligne < coupure)) || echec "sudo doit être obtenu avant de couper le Wi-Fi"
    ((pose < activation)) || echec "l'isolation doit précéder l'activation"
}

test_sudo_limite_au_necessaire() {
    en_service
    principal stop
    fin_start 0
    local autres
    autres=$(grep '^sudo ' "$FAUX/appels.log" |
        grep -Ev "^sudo (install|systemd-run|systemctl stop $UNITE|$BAC/run/wansview-hotspot/wansview-garde.sh nettoyer)")
    egal "" "$autres"
    ne_contient "$(grep -v '^sudo ' "$FAUX/appels.log" | grep '^systemctl')" "stop"
}

test_options_ssid_et_canal() {
    en_service --ssid "Cam salon" --channel 11
    contient "$(journal_start)" "Cam salon"
    contient "$(<"$(profil_temporaire | sed 's/name$/proprietes/')")" "802-11-wireless.channel=11"
}

test_etat_prive() {
    en_service
    egal 700 "$(stat -c %a "$BAC/xdg/wansview-hotspot")"
    egal 600 "$(stat -c %a "$(fichier_etat)")"
}

test_journal_structure_et_sans_secret() {
    en_service
    principal stop
    fin_start 0
    local j="$BAC/home/.local/state/wansview-hotspot/journal.log"
    egal 600 "$(stat -c %a "$j")"
    contient "$(<"$j")" "niveau=INFO session="
    secret_absent
}

# --------------------------------------------------------------- restauration

test_ctrl_c_restaure() {
    en_service
    kill -INT -- "-$PID_START"
    fin_start 0
    wifi_restaure
}

test_sigterm_restaure() {
    en_service
    kill -TERM "$PID_START"
    fin_start 0
    wifi_restaure
}

test_fermeture_du_terminal_restaure() {
    en_service
    kill -HUP -- "-$PID_START"
    fin_start 0
    wifi_restaure
}

test_stop_depuis_un_autre_terminal() {
    en_service
    principal stop
    egal 0 "$CODE" "$SORTIE"
    fin_start 0
    wifi_restaure
}

test_double_stop_sans_effet() {
    en_service
    principal stop
    fin_start 0
    : >"$FAUX/appels.log"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" "Rien à arrêter"
    aucune_modification
}

test_stop_sans_session() {
    principal stop
    egal 0 "$CODE" "$SORTIE"
    aucune_modification
}

test_wifi_initialement_deconnecte() {
    faux_peripherique "$IFACE_WIFI" wifi disconnected
    en_service
    principal stop
    fin_start 0
    rien_ne_reste
    egal disconnected "$(faux_lire "dev/$IFACE_WIFI/state")"
    egal yes "$(faux_lire "dev/$IFACE_WIFI/autoconnect")"
    ne_contient "$(appels)" "connection up uuid $UUID_INITIAL"
}

test_autoconnect_initialement_desactive() {
    echo no >"$FAUX/dev/$IFACE_WIFI/autoconnect"
    en_service
    principal stop
    fin_start 0
    egal no "$(faux_lire "dev/$IFACE_WIFI/autoconnect")"
    egal "$UUID_INITIAL" "$(faux_lire "dev/$IFACE_WIFI/uuid")"
}

test_radio_initialement_desactivee() {
    echo disabled >"$FAUX/nm/radio"
    faux_peripherique "$IFACE_WIFI" wifi disconnected
    en_service
    egal enabled "$(faux_lire nm/radio)"
    principal stop
    fin_start 0
    rien_ne_reste
    egal disabled "$(faux_lire nm/radio)"
}

test_reconnexion_initiale_impossible() {
    en_service
    faux_echec reconnexion
    principal stop
    fin_start 0
    contient "$(journal_start)" "reconnexion"
    rien_ne_reste
}

# ------------------------------------------------- refus sans rien modifier

refus() { # <code> <options de start...>
    local code=$1
    shift
    executer bac_env bash "$PRINCIPAL_SH" start "$@" <<<"$MDP"
    egal "$code" "$CODE" "$SORTIE"
    aucune_modification
    ne_contient "$SORTIE" "$MDP"
}

test_refus_en_root() {
    executer bac_env env WH_TEST_EUID=0 bash "$PRINCIPAL_SH" start
    egal 4 "$CODE" "$SORTIE"
    egal "" "$(appels)"
}

test_options_inconnues_ou_incompletes() {
    refus 2 --inconnue
    refus 2 --ssid
    refus 2 --channel
    principal
    egal 2 "$CODE"
    principal demarrer
    egal 2 "$CODE"
    principal stop --channel 3
    egal 2 "$CODE"
}

test_injection_dans_les_arguments() {
    refus 2 --ssid "x; touch $BAC/pwn"
    refus 2 --ssid "\$(touch $BAC/pwn)"
    refus 2 --channel "a[\$(touch $BAC/pwn)]"
    refus 2 --wifi-iface "\$(touch $BAC/pwn)"
    refus 2 --eth-iface "a[\$(touch $BAC/pwn)]"
    absent "$BAC/pwn"
}

test_canal_12() { refus 3 --channel 12; }

test_sans_ethernet() {
    echo unavailable >"$FAUX/dev/$IFACE_ETH/state"
    refus 3
}

test_route_par_vpn() {
    echo "1.1.1.1 dev tailscale0 src 100.64.0.3" >"$FAUX/ip/route_get"
    refus 3
}

test_point_d_acces_non_pris_en_charge() {
    sed -i '/\* AP$/d' "$FAUX/phy/phy0"
    refus 3
}

test_dependance_manquante() {
    rm "$BAC/bin/dnsmasq"
    refus 3
}

test_plusieurs_cartes() {
    faux_peripherique wlan1 wifi disconnected
    faux_wifi wlan1 phy1
    faux_phy phy1
    refus 3
    en_service --wifi-iface wlan1
    egal AP "$(faux_lire dev/wlan1/iwtype)"
    egal "$UUID_INITIAL" "$(faux_lire "dev/$IFACE_WIFI/uuid")" "l'autre carte reste connectée"
}

test_mot_de_passe_invalide() {
    MDP="court$((RANDOM % 9))"
    refus 2
}

test_mot_de_passe_absent() {
    executer bac_env bash "$PRINCIPAL_SH" start </dev/null
    egal 2 "$CODE" "$SORTIE"
    aucune_modification
}

# ------------------------------------------------------- échecs en cours de route

echec_au_demarrage() { # <code attendu>
    demarrer
    fin_start "$1"
    ne_contient "$(journal_start)" "Point d'accès actif"
    wifi_restaure
}

test_creation_du_profil_impossible() {
    faux_echec ajout
    echec_au_demarrage 6
}

test_echec_d_activation() {
    faux_echec activation
    echec_au_demarrage 9
}

test_activation_sans_mode_ap() {
    faux_echec activation_sans_ap
    echec_au_demarrage 9
}

test_echec_nftables_jamais_de_point_d_acces() {
    faux_echec nft
    echec_au_demarrage 8
    ne_contient "$(appels)" "passwd-file"
}

test_echec_de_systemd_run() {
    faux_echec systemd_run
    echec_au_demarrage 8
    ne_contient "$(appels)" "device disconnect"
}

test_sudo_refuse_wifi_intact() {
    faux_echec sudo
    echec_au_demarrage 8
    ne_contient "$(appels)" "device disconnect"
    ne_contient "$(appels)" "connection up"
}

test_copie_du_garde_differente() {
    faux_echec copie_alteree
    echec_au_demarrage 8
    ne_contient "$(appels)" "systemd-run"
}

test_ecriture_dans_etc_a_la_creation() {
    faux_echec ecriture_etc
    echec_au_demarrage 7
    ne_contient "$(appels)" "sudo"
    contient "$(journal_start)" "/etc"
}

test_profil_au_nom_netplan() {
    faux_echec fichier_netplan
    echec_au_demarrage 7
}

test_ecriture_dans_etc_a_l_activation() {
    faux_echec activation_ecrit_etc
    echec_au_demarrage 7
}

# --------------------------------------------------- surveillance et pannes

test_double_lancement() {
    en_service
    : >"$FAUX/appels.log"
    executer bac_env bash "$PRINCIPAL_SH" start <<<"$MDP"
    egal 5 "$CODE" "$SORTIE"
    ne_contient "$(appels)" "connection add"
    ne_contient "$(appels)" "connection delete"
    egal AP "$(faux_lire "dev/$IFACE_WIFI/iwtype")"
}

test_processus_principal_tue() {
    en_service
    kill -KILL "$PID_START"
    attendre "le garde coupe le point d'accès" service_arrete
    absent "$FAUX/nft/projet"
    egal "" "$(profil_temporaire)"
    egal managed "$(faux_lire "dev/$IFACE_WIFI/iwtype")"
    # L'état subsiste : un nouveau « start » est refusé, « stop » restaure.
    executer bac_env bash "$PRINCIPAL_SH" start <<<"$MDP"
    egal 5 "$CODE" "$SORTIE"
    contient "$SORTIE" "stop"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    wifi_restaure
}

test_garde_tue() {
    en_service
    local pid
    read -r pid <"$FAUX/unit/$UNITE.pid"
    kill -KILL "$pid"
    fin_start 8
    wifi_restaure
}

test_table_alteree() {
    en_service
    sed -i "/chain input {/a\\		accept" "$FAUX/nft/projet"
    fin_start 8
    contient "$(journal_start)" "règles nftables modifiées"
    wifi_restaure
}

test_garde_fige() {
    AGE_MAX=1
    en_service
    local pid
    read -r pid <"$FAUX/unit/$UNITE.pid"
    kill -STOP "$pid"
    fin_start 8
    wifi_restaure
}

test_point_d_acces_coupe_de_l_exterieur() {
    en_service
    bac_env nmcli connection down uuid "$(basename "$(dirname "$(profil_temporaire)")")"
    fin_start 8
    wifi_restaure
}

# ------------------------------------------------------ orphelins et reprises

test_profil_orphelin_sans_etat() {
    faux_connexion 55555555-5555-4555-8555-555555555555 wansview-hotspot-tmp /run/x
    executer bac_env bash "$PRINCIPAL_SH" start <<<"$MDP"
    egal 5 "$CODE" "$SORTIE"
    ne_contient "$(appels)" "connection add"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    egal "" "$(profil_temporaire)"
}

test_garde_orphelin_sans_etat() {
    en_service
    rm "$(fichier_etat)"
    kill -KILL "$PID_START"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    attendre "service arrêté" service_arrete
    absent "$FAUX/nft/projet"
    egal "" "$(profil_temporaire)"
}

test_table_orpheline() {
    mkdir -p "$BAC/run/wansview-hotspot"
    printf 'session=x\nstatut=arrete\ntable=conservee\n' >"$BAC/run/wansview-hotspot/etat"
    reussit 'wh_poser_regles "$@"' "$IFACE_WIFI" "$IFACE_ETH"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    absent "$FAUX/nft/projet"
}

test_restauration_incomplete_puis_reprise() {
    en_service
    faux_echec delete
    principal stop
    egal 10 "$CODE" "$SORTIE"
    fin_start 10
    existe "$(fichier_etat)"
    existe "$FAUX/nft/projet"
    rm "$FAUX/echec/delete"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    wifi_restaure
}

test_networkmanager_muet_restauration_incomplete() {
    en_service
    faux_echec liste_profils
    principal stop
    egal 10 "$CODE" "$SORTIE"
    fin_start 10
    existe "$(fichier_etat)"
    rm "$FAUX/echec/liste_profils"
    principal stop
    egal 0 "$CODE" "$SORTIE"
    wifi_restaure
}

test_echec_de_lancement_sans_second_sudo() {
    faux_echec systemd_run
    echec_au_demarrage 8
    ne_contient "$(appels)" "nettoyer"
}

test_etat_corrompu_jamais_execute() {
    mkdir "$BAC/xdg/wansview-hotspot"
    printf 'session=$(touch %s)\nwifi=a;b\n' "$BAC/pwn" >"$(fichier_etat)"
    principal stop
    [[ $CODE -ne 0 ]] || echec "un état invalide doit être signalé"
    absent "$BAC/pwn"
    ne_contient "$(appels)" "connection delete"
}

# --------------------------------------------------------------------- status

test_status_inactif() {
    principal status
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" "inactif"
    contient "$SORTIE" "$IFACE_ETH"
    aucune_modification
}

test_status_actif_avec_clients() {
    en_service
    echo "10.42.0.23 lladdr aa:bb:cc:dd:ee:ff REACHABLE" >"$FAUX/ip/voisins"
    principal status
    egal 0 "$CODE" "$SORTIE"
    contient "$SORTIE" "actif"
    contient "$SORTIE" "Wansview-Setup"
    contient "$SORTIE" "10.42.0.23"
    contient "$SORTIE" "confirmée"
    ne_contient "$SORTIE" "$MDP"
}

test_status_isolation_non_garantie() {
    en_service
    kill -KILL "$PID_START"
    attendre "service arrêté" service_arrete
    echo AP >"$FAUX/dev/$IFACE_WIFI/iwtype"
    local uuid
    uuid=$(sed -n 's/^uuid_ap=//p' "$(fichier_etat)")
    echo "$uuid" >"$FAUX/dev/$IFACE_WIFI/uuid"
    principal status
    egal 8 "$CODE" "$SORTIE"
    contient "$SORTIE" "NON GARANTIE"
}

# ------------------------------------------------------------------- statique

test_aucun_eval_ni_flush() {
    local fichiers
    fichiers=("$RACINE_OUTIL"/*.sh "$RACINE_OUTIL"/lib/*.sh)
    egal "" "$(grep -nE '(^|[^[:alnum:]_-])eval([^[:alnum:]_-]|$)' "${fichiers[@]}")" "eval interdit"
    egal "" "$(grep -nE 'nft.*flush|flush ruleset|iptables|ufw ' "${fichiers[@]}" | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')"
}
