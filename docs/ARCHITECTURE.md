# Architecture

Pour déployer, voir le [README](../README.md).

## Flux

| Flux | Chemin | Contrôle |
|---|---|---|
| spoke → Internet | Private → Pub → Hub → firewall → Public Gateway | firewall, NAT |
| spoke A → spoke B | → Hub → firewall | bloqué par défaut ; NACL du spoke cible |
| Pub ↔ Private (même spoke) | peering direct | NACL |
| on-prem (VPN) ↔ spoke | VPN → Egress → Hub → firewall | règles de `policy.yaml` (aucune par défaut) et `nacl_inbound` |
| on-prem (Interlink) ↔ Private | Interlink → Hybrid → Private | sans firewall (`hybrid_bypass`) |
| Internet → exposition d'un spoke | Edge Services → Load Balancer du spoke | TLS et WAF, hors firewall |
| Internet → exposition du hub | Edge Services → Load Balancer du hub (Egress) → firewall → backend | TLS et WAF ; règle `[HUB]` de l'exposition |

## Adressage

Le hub occupe `10.0.4.0/24` (Egress), `10.0.5.0/24` (Hybrid), `10.0.6.0/24` (Mgmt), `172.16.0.0/24` (Hub) et `10.255.0.0/24` (heartbeat HA). Chaque spoke prend sa place dans `10.64.0.0/10` d'après son `index` : un `/22` Pub dans `10.64.0.0/12` et un `/21` Private dans `10.96.0.0/11`. Le spoke d'index 1 a ainsi `10.64.4.0/22` et `10.96.8.0/21`. Si ces plages chevauchent l'on-prem, changez les arguments `cidrs` et `spoke_supernet` de `module "hub"` avant le premier apply.

## Filtrage

La politique du firewall refuse tout ce qu'elle n'ouvre pas. Par défaut, elle bloque le trafic entre spokes et laisse sortir les spokes vers Internet. Le réseau Egress du hub n'atteint un spoke que sur les backends des expositions du hub : une règle `[HUB]` par exposition, limitée aux IP et au port de ses backends. Les flux on-prem et les exceptions entre spokes se déclarent dans `policy.yaml`. Une exposition passe toujours par Edge Services, qui porte le certificat TLS et le WAF, et son Load Balancer n'accepte que les IP d'Edge Services.

<img alt="Filtrage : un flux vers une VM de spoke franchit le FortiGate entre VPC, la NACL à la frontière du VPC, puis le security group de la carte." src="lz-security.svg">

## Haute disponibilité

Un seul firewall est actif, le primaire FGCP. Les deux nœuds échangent un heartbeat unicast sur le réseau HA et portent deux adresses virtuelles (VIP) de données, Hub et Egress, réservées dans l'IPAM.

## Administration

Les nœuds n'ont aucune IP publique. Leur port de management (`port2`) est sur le réseau `mgmt`, isolé, où est rattachée la Public Gateway de chaque zone (masquerade, route par défaut, bastion SSH). On joint un nœud par le bastion de sa zone, depuis une adresse de `admin_cidrs`.

<img alt="Administration : chaque firewall se joint par le bastion de la Public Gateway de sa zone, dans un VPC de management isolé." src="lz-admin.svg">

## Premier démarrage

Terraform range dans les user data cloud-init de l'Instance la licence du nœud, le compte `admin` avec ses clés SSH et toute la plateforme (management, interfaces, routes, HA). Scaleway présente ces user data sur un CD-ROM NoCloud aux Instances sans IP publique. FortiOS (7.4.5+ ou 7.6.0+) le lit au premier démarrage, installe la licence, redémarre et applique la CLI. Il ne le relit jamais : on part toujours du qcow2 d'usine, et changer la plateforme d'un nœud veut dire le reconstruire.

<img alt="Premier démarrage : Terraform écrit les user data, FortiOS les lit une seule fois sur le CD-ROM NoCloud, puis fortigate.sh vérifie le nœud par le bastion et pousse la politique." src="lz-provisioning.svg">

Un nœud est prêt en 3 min 30 environ, et les deux démarrent en parallèle. `fortigate.sh ready` vérifie alors chaque nœud par le bastion (clé `admin` acceptée, licence valide, ports dans le bon ordre), puis `fortigate.sh policy` pousse la politique sur le primaire, qui la synchronise. Terraform efface enfin les user data de l'Instance, qui contiennent la licence et les mots de passe. Pendant les quelques minutes du premier démarrage, l'API Instance permet de les lire, à tout opérateur du projet.

## Bascule

Le routeur du VPC suit la réservation IPAM de la VIP du Hub et ignore les ARP gratuits. Quand un nœud devient primaire, une automation FortiOS (événement 37892 `ha_role=primary`, répétée à 0, 10 et 30 s, plus un rattrapage toutes les heures) appelle une Serverless Function privée (`modules/hub/failover.tf`, `modules/hub/ipam_follow/handler.py`). La fonction déplace les deux VIP de données vers ce nœud dans l'IPAM. Le firewall ne détient qu'une clé IAM limitée à `FunctionsPrivateAccess`, et la clé de la fonction est limitée à `IPAMFullAccess` sur le projet.

<img alt="Bascule : le routeur VPC suit l'IPAM, pas le GARP ; le nouveau primaire FortiGate appelle une Serverless Function qui déplace la VIP dans l'IPAM." src="lz-ha.svg">

Mesures du 2 novembre 2026, avec deux VM de spoke qui envoient 10 pings par seconde vers Internet à travers le firewall :

| Événement | Perte | Session HTTPS en cours |
|---|---|---|
| arrêt du primaire | 1 s | conservée |
| bascule forcée (`execute ha failover set 1`) | 0,2 s | conservée |
| retour de l'ancien primaire | aucune, pas de rebascule | conservée |

La fonction est écrite en Python, sans dépendance, et garde une instance chaude. L'appel du firewall sort par la Public Gateway et joint son point d'accès public en HTTPS signé. L'attacher à un Private Network n'y changerait rien : Scaleway n'y route que le trafic sortant de la fonction, pas l'appel entrant ([limites](https://www.scaleway.com/en/docs/serverless-functions/reference-content/functions-private-networks/)). La bascule automatique dépend donc de la sortie Internet du hub, comme le trafic Internet des spokes. Deux PGW dans deux zones, le rattrapage horaire et la sortie `failover_commands` couvrent ce risque. Quand Scaleway acceptera l'appel privé, il suffira d'attacher la fonction au Private Network de management et de changer l'URL appelée dans `fortigate-policy.conf.tftpl`.
