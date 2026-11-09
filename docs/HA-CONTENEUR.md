# Haute disponibilité et conteneur de bascule

Mesures sur FortiOS 8.0.2, fw1 et fw2 dans deux zones, en FGCP actif-passif. Une VM de spoke envoie 10 pings par seconde vers un autre spoke (est-ouest) et vers `1.1.1.1` (Internet).

## Next hop du routeur VPC

Le routeur envoie le trafic du hub vers la dernière MAC annoncée, par Gratuitous ARP ou par écriture IPAM. Il n'interroge jamais la VIP.

| Événement | Résultat |
|---|---|
| Gratuitous ARP broadcast, IPAM inchangée | le trafic change de nœud en 0,1 s environ |
| Écriture IPAM vers le primaire, Gratuitous ARP coupé | fin du black hole en moins de 0,1 s |
| Écriture IPAM vers le secondaire, cluster sain | black hole immédiat jusqu'à l'écriture suivante |

Les ARP unicast du nouveau primaire, une modification de règle VPC et l'ARP d'un nouveau client ne déplacent pas le next hop.

La VIP Egress ne dépend pas de l'IPAM : les Public Gateways font de l'ARP toutes les 30 s environ. Une IPAM fausse pendant 45 s n'a coûté aucun ping.

## Déroulé d'une bascule

1. Après 20 heartbeats manqués à 200 ms sur `port4`, soit 4 s, le secondaire se déclare primaire.
2. Le primaire envoie 60 Gratuitous ARP à 1 par seconde sur les deux VIP. Il le fait à chaque élection, même s'il reste primaire.
3. L'événement 37892 `ha_role=primary` lance `lz-ipam-follow`. Environ 2,5 s après la bascule, le nouveau primaire appelle une fois le conteneur avec son nom d'hôte et l'heure de l'événement.
4. Le conteneur déplace les deux VIP vers ce nœud dans l'IPAM.

Les deux nœuds portent la même IP sur `port3`, et seul le primaire répond aux ARP. Le secondaire laisse tomber les trames reçues et son propre trafic sort par le primaire.

Le rattrapage horaire de la minute 7 ne part que du primaire. Le secondaire le journalise et garde l'appel, qui peut partir plus tard si ce nœud devient primaire. Les répétitions à 10 et 30 s de l'automation ne partent pas.

## Mesures de bascule

| Scénario | Gratuitous ARP | Conteneur | Coupure |
|---|---|---|---|
| Bascule commandée | actif | désactivé | 0 à 3,2 s |
| Bascule commandée | actif | actif | 0,3 à 3,4 s |
| Bascule commandée | désactivé | actif | 10,5 à 11,1 s |
| Bascule commandée | désactivé | désactivé | black hole, encore en cours à 328 s |
| Ports hub, egress et HA du primaire coupés | actif | désactivé | 5,1 s |
| Ports hub, egress et HA du primaire coupés | actif | actif | 5,9 s |
| `scw instance server stop` du primaire | actif | désactivé | 1,24 s |

Le VPN et un Load Balancer du réseau Egress partagent le next hop de la VIP du hub et basculent avec le reste : 0 à 2,2 s en bascule commandée, 10,5 à 11 s sans Gratuitous ARP.

Sans Gratuitous ARP, le cache ARP du conteneur garde l'ancienne MAC de la VIP. Son SYN-ACK part vers l'ancien primaire jusque vers T+9,5 s, d'où les 11 s. Avec le Gratuitous ARP, il arrive en 2 ms et l'appel complet prend environ 1,5 s.

Avec fw2 arrêté pendant 3 h, l'IPAM sur sa carte absente et les automations désactivées, 8 pings sur 107 523 sont perdus en est-ouest et 1 sur 107 533 vers Internet, tous dans les 10 premières minutes. La cause n'a pas été cherchée. fw2 a ensuite rejoint le cluster en 41 s, sans perte.

## Appel tardif

FortiOS peut envoyer un appel longtemps après son événement : un rattrapage est parti 66 s plus tard, 16 s après que ce nœud était devenu primaire. Un appel qui nomme un secondaire déplace l'IPAM vers lui et coupe tout le hub. Provoquée, cette erreur a duré 120,2 s, jusqu'au rattrapage de la minute 7.

Chaque appel porte donc `%%log.eventtime%%`, et le conteneur refuse en HTTP 409 tout appel plus ancien que le dernier vu. Rejoué, le même appel a été refusé sans perte. Cette heure vit en mémoire, d'où `max_scale = 1` : un appel tardif juste après un redémarrage du conteneur passerait encore, comme un appel récent qui nomme le mauvais nœud.

## Panne d'un firewall vue des spokes

Ports hub, egress et HA d'un nœud coupés d'un coup : 11 essais sur le primaire, dans les deux sens, et 2 sur le secondaire.

| Flux depuis le spoke | Panne du primaire | Panne du secondaire |
|---|---|---|
| Pub ↔ Private du même spoke (peering direct) | 0 perte | 0 perte |
| Ping est-ouest | 4,1 à 7,2 s | 0 perte |
| Ping Internet | 4,1 à 7,4 s, puis 2,3 à 3,4 s vers T+14 s (10 essais sur 11) | 0 perte |
| Nouvelles connexions est-ouest | 4 à 7 requêtes en échec | 0 |
| Nouvelles connexions Internet | 4 à 10 requêtes en échec | 0 |
| Session TCP longue est-ouest | conservée, silence de 6,7 à 13,8 s | conservée, 0 s |
| Session TCP longue Internet | conservée, silence de 2,8 à 8 s, puis de 62 à 135 s sur 9 essais | conservée, 0 s |

Le Gratuitous ARP rétablit le trafic entre T+4 et T+7 s et le conteneur écrit l'IPAM entre T+8 et T+11 s. Aucune intervention n'est nécessaire.

### Silence des sessions Internet

Un secondaire ne fait pas tourner ses link monitors et garde leur dernier état. S'il a perdu ses ports, cet état reste `dead`, encore 66 min plus tard dans un test. Quand il devient primaire, il repart de `dead`, et ses routes par défaut tombent 2 s vers T+14 s. C'est la seconde coupure Internet. La cause de ce délai de 10 s après l'élection n'est pas connue.

| Survivant au moment de la panne | Essais | Seconde coupure |
|---|---|---|
| ports perdus depuis son dernier passage primaire | 12 | 12 |
| ports jamais perdus depuis | 3 | 0 |
| link monitors remis à zéro avant la panne | 3 | 0 |

Les sessions Internet disparaissent alors du firewall. Celle d'un client qui attend des données reste muette jusqu'à son prochain paquet sortant, qui la recrée en sloppy state. Le silence dépend donc du keepalive du client :

| Keepalive du client | Silence |
|---|---|
| 5 s | 5 à 26 s |
| 60 s, le défaut de curl | 62 à 135 s |
| aucun | 28 s, 137 s, ou pas de reprise avant la fin du test |

Après remise à zéro des link monitors ([procédure](OPERATIONS.md#après-la-réparation-dun-firewall)), une session longue reprend en 3,4 à 6,9 s, sans reset. `failtime 20`, `snat-route-change enable` et `route-hold 40` ne changent rien.

### Retour du nœud

Le nœud revenu est in-sync 9 s après la remise des ports. `override` étant désactivé, le rôle de primaire suit deux règles, vérifiées sur 15 retours :

- Si l'uptime FGCP diffère de plus de 300 s (`ha-uptime-diff-margin`), le plus ancien est primaire. Le nœud revenu compte depuis son retour : il revient donc secondaire, sans coupure.
- Sinon, la priorité tranche : fw1 (200) contre fw2 (100).

Un failback n'arrive que si les deux nœuds ont subi une panne à moins de 300 s d'écart. Il coûte au plus 1,2 s en est-ouest et 4,3 s vers Internet, sans reset.

## Perte d'une zone, simulée

Scaleway ne permet pas d'éteindre une zone. Le test coupe les ports du firewall de la zone et rend sa Public Gateway injoignable depuis le survivant, avec le primaire dans la zone perdue.

| Mesure | Zone de la Public Gateway préférée | Zone de la Public Gateway de secours |
|---|---|---|
| Ping est-ouest | 5,1 s | 5 s |
| Ping Internet | 16,4 s | 5 s, puis 3,1 s |
| Nouvelles connexions Internet | 14 requêtes en échec | 8 requêtes en échec |
| Session TCP est-ouest | conservée, 6,7 s | conservée, 6,7 s |
| Sessions TCP Internet | 3 sur 3 coupées, l'IP publique change | conservées, silence de 6 à 137 s |
| VIP dans l'IPAM | T+10 s | T+8 s |

Le retour n'a fait perdre aucun ping. Quand la Public Gateway préférée revient, les sessions ouvertes pendant la perte sont coupées à leur tour.

## Rôle du conteneur

Le conteneur ne raccourcit pas la coupure. Il la borne à 11 s si le Gratuitous ARP reste sans effet, et il garde l'IPAM juste pour la console, l'API et `failover_commands`.

Aucune des 18 pannes provoquées avec le Gratuitous ARP actif n'a eu besoin de lui. Si Scaleway garantit que le routeur suit le Gratuitous ARP, il ne sert plus qu'à garder l'IPAM juste. Sinon, il est le seul chemin qui repose sur une API publique. Il coûte une instance toujours chaude, deux clés IAM et un appel HTTPS sans vérification du nom.

## Alternatives testées

Les SDN Connectors Fortinet déplacent par API ce que le réseau rattache à une carte. Deux équivalents ont été testés sur Scaleway :

- Une route VPC vers une carte (`nexthop_resource_id`, avec `nexthop_private_network_id` obligatoire) ignore le Gratuitous ARP et ne bouge que par API, en moins de 2 s. Le déploiement n'en utilise pas.
- Une IP flexible est zonale et ne s'attache pas à un nœud d'une autre zone.
