#!/usr/bin/env python3
"""Serveurs et clients minimaux du test d'isolation en espace de noms réseau.

  serveurs.py serveur [--tcp HOTE:PORT]... [--udp HOTE:PORT]... [--wsd IP]
  serveurs.py tcp HOTE PORT
  serveurs.py udp HOTE PORT [--port-source N]

Les clients sortent avec le code 0 si le serveur répond, 1 sinon. En UDP,
n'importe quelle réponse compte.
"""

import argparse
import selectors
import socket
import sys

DELAI = 1.5
GROUPE_WSD = "239.255.255.250"
PORT_WSD = 3702


def point_d_ecoute(texte: str) -> tuple[str, int]:
    hote, _, port = texte.rpartition(":")
    return hote.strip("[]"), int(port)


def famille(hote: str) -> socket.AddressFamily:
    return socket.AF_INET6 if ":" in hote else socket.AF_INET


def reponse_wsd(adresse: str) -> bytes:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>'
        '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
        "<e:Body><d:ProbeMatches><d:ProbeMatch>"
        f"<d:XAddrs>http://{adresse}/onvif/device_service</d:XAddrs>"
        "</d:ProbeMatch></d:ProbeMatches></e:Body></e:Envelope>"
    ).encode()


def ouvrir_tcp(hote: str, port: int) -> socket.socket:
    prise = socket.socket(famille(hote), socket.SOCK_STREAM)
    prise.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    prise.bind((hote, port))
    prise.listen()
    return prise


def ouvrir_udp(hote: str, port: int) -> socket.socket:
    prise = socket.socket(famille(hote), socket.SOCK_DGRAM)
    prise.bind((hote, port))
    return prise


def ouvrir_wsd(adresse: str) -> socket.socket:
    prise = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    prise.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    prise.bind(("0.0.0.0", PORT_WSD))
    adhesion = socket.inet_aton(GROUPE_WSD) + socket.inet_aton(adresse)
    prise.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, adhesion)
    return prise


def servir(options: argparse.Namespace) -> None:
    selecteur = selectors.DefaultSelector()
    for hote, port in options.tcp:
        selecteur.register(ouvrir_tcp(hote, port), selectors.EVENT_READ, "tcp")
    for hote, port in options.udp:
        selecteur.register(ouvrir_udp(hote, port), selectors.EVENT_READ, "udp")
    if options.wsd:
        selecteur.register(ouvrir_wsd(options.wsd), selectors.EVENT_READ, "wsd")
    print("PRET", flush=True)

    while True:
        for cle, _ in selecteur.select():
            prise = cle.fileobj
            try:
                if cle.data == "tcp":
                    connexion, _ = prise.accept()
                    with connexion:
                        connexion.sendall(b"ok")
                else:
                    _, emetteur = prise.recvfrom(65535)
                    message = reponse_wsd(options.wsd) if cle.data == "wsd" else b"ok"
                    prise.sendto(message, emetteur)
            except OSError as erreur:
                # Attendu quand le pare-feu bloque la réponse.
                print(f"réponse non envoyée : {erreur}", file=sys.stderr)


def client_tcp(options: argparse.Namespace) -> int:
    try:
        with socket.create_connection((options.hote, options.port), timeout=DELAI) as prise:
            return 0 if prise.recv(2) == b"ok" else 1
    except OSError:
        return 1


def client_udp(options: argparse.Namespace) -> int:
    with socket.socket(famille(options.hote), socket.SOCK_DGRAM) as prise:
        prise.settimeout(DELAI)
        try:
            if options.port_source:
                prise.bind(("", options.port_source))
            prise.sendto(b"sonde", (options.hote, options.port))
            prise.recv(65535)
        except OSError:
            return 1
        return 0


def main() -> int:
    analyseur = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commandes = analyseur.add_subparsers(dest="commande", required=True)
    serveur = commandes.add_parser("serveur")
    serveur.add_argument("--tcp", action="append", default=[], type=point_d_ecoute)
    serveur.add_argument("--udp", action="append", default=[], type=point_d_ecoute)
    serveur.add_argument("--wsd")
    for nom in ("tcp", "udp"):
        client = commandes.add_parser(nom)
        client.add_argument("hote")
        client.add_argument("port", type=int)
        if nom == "udp":
            client.add_argument("--port-source", type=int)
    options = analyseur.parse_args()
    if options.commande == "serveur":
        servir(options)
        return 0
    return client_tcp(options) if options.commande == "tcp" else client_udp(options)


if __name__ == "__main__":
    sys.exit(main())
