#!/usr/bin/env python3
"""Découverte ONVIF (WS-Discovery) depuis une adresse locale choisie.

La sonde part de l'adresse du point d'accès : sans cela, le multicast suivrait
la route par défaut, c'est-à-dire l'Ethernet. Les réponses viennent d'appareils
non fiables : elles sont bornées et nettoyées avant affichage.

Codes de sortie : 0 au moins une réponse, 1 aucune, 2 erreur.
"""

import argparse
import ipaddress
import math
import socket
import sys
import time
import uuid
import xml.etree.ElementTree as ET

GROUPE = "239.255.255.250"
PORT = 3702
TAILLE_MAXIMALE = 65535
LONGUEUR_AFFICHEE = 200
REPONSES_MAXIMALES = 50
VALEURS_PAR_REPONSE = 8

SONDE = """<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
 xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
 xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
 xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
<e:Header>
<w:MessageID>urn:uuid:{identifiant}</w:MessageID>
<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
<w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
</e:Header>
<e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
</e:Envelope>
"""


class ErreurSonde(Exception):
    """La sonde n'a pas pu être envoyée."""


class ReponseRefusee(Exception):
    """Réponse illisible ou potentiellement dangereuse."""


def adresse_ipv4(texte: str) -> str:
    try:
        return str(ipaddress.IPv4Address(texte))
    except ValueError as erreur:
        raise argparse.ArgumentTypeError("adresse IPv4 attendue") from erreur


def port_valide(texte: str) -> int:
    if not texte.isascii() or not texte.isdigit() or not 0 < int(texte) <= 65535:
        raise argparse.ArgumentTypeError("port attendu entre 1 et 65535")
    return int(texte)


def duree_valide(texte: str) -> float:
    try:
        duree = float(texte)
    except ValueError as erreur:
        raise argparse.ArgumentTypeError("durée en secondes attendue") from erreur
    if not math.isfinite(duree) or not 0 < duree <= 60:
        raise argparse.ArgumentTypeError("durée attendue entre 0 et 60 secondes")
    return duree


def nettoyer(texte: str) -> str:
    """Retire les caractères non imprimables et borne la longueur."""
    return "".join(c for c in texte if c.isprintable())[:LONGUEUR_AFFICHEE]


def analyser(donnees: bytes) -> list[tuple[str, str]]:
    """Retourne les couples (libellé, valeur) d'une réponse ProbeMatches."""
    try:
        texte = donnees.decode("utf-8")
    except UnicodeDecodeError as erreur:
        raise ReponseRefusee("encodage inattendu") from erreur
    # Pas de DTD : aucune expansion d'entité sur des données non fiables.
    if "<!DOCTYPE" in texte or "<!ENTITY" in texte or "\x00" in texte:
        raise ReponseRefusee("contenu interdit")
    try:
        racine = ET.fromstring(texte)
    except (ET.ParseError, ValueError, LookupError) as erreur:
        raise ReponseRefusee("XML illisible") from erreur

    libelles = {"XAddrs": "adresse", "Scopes": "portée"}
    resultats = []
    for element in racine.iter():
        libelle = libelles.get(element.tag.rsplit("}", 1)[-1])
        if libelle and element.text:
            for valeur in element.text.split()[:VALEURS_PAR_REPONSE]:
                resultats.append((libelle, nettoyer(valeur)))
    if not resultats:
        raise ReponseRefusee("aucune information ONVIF")
    return resultats


def sonder(source: str, cible: str, port: int, duree: float) -> int:
    """Envoie la sonde et affiche les réponses. Retourne leur nombre."""
    message = SONDE.format(identifiant=uuid.uuid4()).encode()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as prise:
        try:
            prise.bind((source, 0))
            if ipaddress.IPv4Address(cible).is_multicast:
                prise.setsockopt(
                    socket.IPPROTO_IP, socket.IP_MULTICAST_IF, socket.inet_aton(source)
                )
                prise.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
            prise.sendto(message, (cible, port))
        except OSError as erreur:
            raise ErreurSonde(
                f"envoi impossible depuis {source} : {erreur.strerror}"
            ) from erreur
        return ecouter(prise, duree)


def ecouter(prise: socket.socket, duree: float) -> int:
    limite = time.monotonic() + duree
    nombre = 0
    while nombre < REPONSES_MAXIMALES and (reste := limite - time.monotonic()) > 0:
        prise.settimeout(reste)
        try:
            donnees, (emetteur, _) = prise.recvfrom(TAILLE_MAXIMALE)
        except TimeoutError:
            break
        except OSError as erreur:
            print(f"réception interrompue : {erreur.strerror}", file=sys.stderr)
            break
        try:
            informations = analyser(donnees)
        except ReponseRefusee as raison:
            print(f"réponse de {emetteur} ignorée : {raison}", file=sys.stderr)
            continue
        nombre += 1
        print(f"Réponse de {emetteur}")
        for libelle, valeur in informations:
            print(f"  {libelle} : {valeur}")
    return nombre


def main(arguments: list[str] | None = None) -> int:
    analyseur = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    analyseur.add_argument("--source", required=True, type=adresse_ipv4,
                           help="adresse locale d'émission, par exemple 10.42.0.1")
    analyseur.add_argument("--cible", default=GROUPE, type=adresse_ipv4,
                           help=f"destination (défaut : {GROUPE})")
    analyseur.add_argument("--port", default=PORT, type=port_valide)
    analyseur.add_argument("--duree", default=3.0, type=duree_valide,
                           help="secondes d'écoute (défaut : 3)")
    options = analyseur.parse_args(arguments)
    try:
        nombre = sonder(options.source, options.cible, options.port, options.duree)
    except ErreurSonde as erreur:
        print(f"Erreur : {erreur}", file=sys.stderr)
        return 2
    if nombre == 0:
        print("Aucune réponse ONVIF.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
