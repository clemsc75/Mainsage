#!/usr/bin/env bash
# Table nftables du projet : génération, pose, contrôle d'intégrité, suppression.
# Seule la table « inet wansview_hotspot » portant le commentaire du projet est
# créée ou supprimée. Les autres règles du système ne sont jamais modifiées.
#
# Un « drop » est définitif quelle que soit la table ; un « accept » posé ici
# n'annule pas un « drop » posé ailleurs. D'où les chaînes en « policy accept »
# qui ne font que retirer des droits au trafic du point d'accès.

# Destinations interdites aux clients Wi-Fi (adresses privées ou réservées).
WH_INTERDITS=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
    172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4)

# wh_regles <wifi> <ethernet> [sous-réseaux de l'Ethernet...]
wh_regles() {
    local wifi=${1:-} eth=${2:-} reseau elements
    if ! wh_valider_iface "$wifi" || ! wh_valider_iface "$eth" || [[ $wifi == "$eth" ]]; then
        wh_erreur "Interfaces invalides pour les règles."
        return "$WH_E_USAGE"
    fi
    shift 2
    local interdits=("${WH_INTERDITS[@]}")
    for reseau in "$@"; do
        reseau=$(wh_cidr_reseau "$reseau") || {
            wh_erreur "Sous-réseau invalide pour les règles."
            return "$WH_E_USAGE"
        }
        interdits+=("$reseau")
    done
    printf -v elements '%s, ' "${interdits[@]}"
    elements=${elements%, }

    # Les trois premières lignes remplacent la table en une seule transaction.
    cat <<REGLES
add table inet $WH_TABLE
delete table inet $WH_TABLE
table inet $WH_TABLE {
	comment "$WH_COMMENTAIRE"

	set interdits {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { $elements }
	}

	# Ports du PC ayant émis une sonde WS-Discovery : la réponse de la caméra
	# n'est pas « established », car la sonde partait vers une adresse multicast.
	set decouverte_wsd {
		type inet_service
		size 64
		flags dynamic,timeout
		timeout 10s
	}

	chain output {
		type filter hook output priority filter - 10; policy accept;
		oifname "$wifi" ip daddr 239.255.255.250 udp dport 3702 update @decouverte_wsd { udp sport }
	}

	chain input {
		type filter hook input priority filter - 10; policy accept;
		iifname != "$wifi" return
		meta nfproto ipv6 counter drop
		ct state established,related accept
		udp sport 68 udp dport 67 accept
		ip daddr $WH_IP_AP udp dport 53 accept
		ip daddr $WH_IP_AP tcp dport 53 accept
		ip daddr $WH_IP_AP udp dport @decouverte_wsd accept
		counter drop
	}

	chain forward {
		type filter hook forward priority filter - 10; policy accept;
		iifname "$wifi" meta nfproto ipv6 counter drop
		iifname "$wifi" ip saddr != $WH_RESEAU_AP counter drop
		iifname "$wifi" oifname != "$eth" counter drop
		iifname "$wifi" ip daddr @interdits counter drop
		iifname "$wifi" accept
		oifname "$wifi" iifname "$eth" meta nfproto ipv4 ct state established,related accept
		oifname "$wifi" counter drop
	}
}
REGLES
}

# Affiche « absente », « nous » ou « etrangere ». Échoue si l'état est inconnu.
wh_etat_table() {
    local liste contenu
    liste=$(nft list tables) || return 1
    if [[ $'\n'"$liste"$'\n' != *$'\n'"table inet $WH_TABLE"$'\n'* ]]; then
        echo absente
        return 0
    fi
    contenu=$(nft list table inet "$WH_TABLE") || return 1
    if [[ $contenu == *"comment \"$WH_COMMENTAIRE\""* ]]; then
        echo nous
    else
        echo etrangere
    fi
}

# Empreinte de la table, hors compteurs et hors contenu des ensembles dynamiques,
# plus le contenu de l'ensemble « interdits ».
wh_empreinte() {
    local structure interdits somme
    structure=$(nft -s -t list table inet "$WH_TABLE" 2>/dev/null) || return 1
    interdits=$(nft -s list set inet "$WH_TABLE" interdits 2>/dev/null) || return 1
    somme=$(printf '%s\n%s\n' "$structure" "$interdits" | sha256sum) || return 1
    echo "${somme%% *}"
}

wh_poser_regles() { # <wifi> <ethernet> [sous-réseaux...]
    local etat regles
    etat=$(wh_etat_table) || return "$WH_E_ISOLATION"
    if [[ $etat == etrangere ]]; then
        wh_erreur "Une table inet $WH_TABLE étrangère existe déjà : elle n'est pas touchée."
        return "$WH_E_ISOLATION"
    fi
    regles=$(wh_regles "$@") || return
    nft -f - <<<"$regles" || return "$WH_E_ISOLATION"
}

wh_supprimer_table() {
    local etat
    etat=$(wh_etat_table) || return "$WH_E_ISOLATION"
    case $etat in
        absente) return 0 ;;
        nous) nft delete table inet "$WH_TABLE" || return "$WH_E_ISOLATION" ;;
        *)
            wh_erreur "La table inet $WH_TABLE n'est pas celle du projet : elle est conservée."
            return "$WH_E_ISOLATION"
            ;;
    esac
    [[ $(wh_etat_table) == absente ]] || return "$WH_E_ISOLATION"
}
