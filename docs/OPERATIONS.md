# Exploitation

Après chaque modification : `terraform plan`, relecture, puis `terraform apply`. Les ressources Scaleway changent à l'apply, et la politique du firewall est poussée à chaud. Un réglage de plateforme du firewall (interfaces, HA, passerelles, syslog, licence, clés `admin`) n'atteint un nœud qu'à sa création : il faut le reconstruire.

## Ajouter un spoke

Ajoutez une entrée à `spokes` dans `terraform.tfvars`, avec un `index` unique entre 0 et 1023, puis appliquez. Le firewall n'est pas modifié. Ne changez jamais l'`index` d'un spoke existant : il fixe ses adresses.

Dans la même entrée, `nacl_inbound` ouvre un flux entrant et `hybrid_bypass = true` relie le spoke à Interlink (il faut alors `interlink`). Toute exposition passe par Edge Services : `edge_services_plan` est requis dès que `endpoints` en contient une.

## Retirer un spoke

Supprimez d'abord ce qui est attaché aux Private Networks du spoke (instances, LB, bases). Retirez ensuite ses expositions de `endpoints` et son entrée de `spokes`, puis appliquez.

## Changer la politique du firewall

Modifiez `policy.yaml` (format et exemples dans `policy.yaml.example`), puis appliquez. Les règles sont poussées sur le primaire FGCP, qui synchronise le secondaire, sans redémarrage. Un réglage fait dans le WebUI est écrasé au push suivant. Aucun flux on-prem n'est ouvert par défaut : déclarez-les ici, avec l'alias `ONPREM_VPN`. La variable `policy_file` change le chemin du fichier.

## Reconstruire un firewall

FortiOS ne lit ses user data qu'une fois, au premier démarrage. Un changement de plateforme ou de version passe donc par une reconstruction. Le plan l'annonce par une mise à jour de `module.hub.terraform_data.fw_config`, qui montre la plateforme en clair et les user data sous forme de hash. Reconstruisez un nœud par apply, le secondaire d'abord :

```bash
ssh -J <bastion> admin@<ip-mgmt> 'get system ha status'                     # qui est primaire ?
terraform apply -replace='module.hub.terraform_data.fw_generation["fw2"]'   # le secondaire
# sur le primaire, en SSH interactif : execute ha failover set 1   (confirmer par y)
terraform apply -replace='module.hub.terraform_data.fw_generation["fw1"]'   # l'ancien primaire
```

<img alt="Mise à jour en production : on reconstruit le secondaire, on bascule vers lui, puis on reconstruit l'ancien primaire, qui revient en secondaire." src="lz-rebuild.svg">

Un nœud reconstruit revient en secondaire et le cluster ne rebascule pas. Il peut rester *out-of-sync* 5 à 6 minutes, le temps que le primaire mette à jour ses objets FortiGuard : attendez `in-sync` avant l'étape suivante. Pour changer de version, remplacez le `snapshot_id` d'un nœud, puis de l'autre, dans le même ordre.

## Faire tourner les clés de bascule

```bash
terraform apply -replace='module.hub.scaleway_iam_api_key.fw_invoke'    # clé du firewall
terraform apply -replace='module.hub.scaleway_iam_api_key.ipam_follow'  # clé du conteneur
```

La clé du firewall est repoussée avec la politique, celle du conteneur est redéployée dans le conteneur. Aucun nœud n'est reconstruit. Si une bascule échoue entre-temps, déplacez les VIP à la main avec la ligne du primaire de `terraform output -json failover_commands`.

## Accès direct aux firewalls

Par défaut, on joint les firewalls par le bastion (sortie `access`). Avec `admin_direct_access = true`, chaque Public Gateway redirige aussi ses ports publics vers le nœud de sa zone : `ssh -p 2222 admin@<ip-pgw>` et `https://<ip-pgw>:8443`, que la sortie `access` donne en `direct_ssh` et `direct_webui`. Seules les adresses de `admin_cidrs` passent : les redirections ne filtrent pas la source, le security group des firewalls si. L'option s'active et se retire par un apply, sans reconstruire les nœuds. Le WebUI présente le certificat auto-signé du FortiGate.

## Journaux

Avec `observability = true`, une petite VM du réseau Egress reçoit le syslog des firewalls (RFC 5424, port 514 en UDP et TCP) et Grafana Alloy le pousse dans Cockpit, dans le projet. Le relais n'a ni HA ni TLS : s'il tombe, les firewalls gardent leurs journaux en local, et le trafic ne quitte pas le Private Network. Si le client a déjà un SIEM, laissez `observability = false` et mettez son collecteur dans `firewall.syslog`.

Terraform ajoute l'adresse du relais (`syslog_target` dans la sortie `observability`, 10.0.4.5 avec le plan par défaut) à `firewall.syslog` : les nœuds lui envoient leurs journaux dès leur premier démarrage. Un nœud ne lit ce réglage qu'à sa création : activer `observability` sur un déploiement existant demande de reconstruire les nœuds un à un. La sortie donne aussi `grafana_url` : dans Explore, choisissez la source de logs du projet et filtrez sur `{job="fortigate"}`, puis sur le label `type` (`event`, `utm`…). Dès qu'un collecteur syslog existe, le firewall journalise chaque session Internet des spokes (`type="traffic"`). C'est de loin le plus gros volume de Cockpit : `keep_traffic_log = false` dans `module "observability"` le fait jeter par le relais.

## Détruire

Supprimez d'abord les ressources créées hors Terraform dans le projet (instances, LB, volumes, bases, buckets). Puis :

```bash
terraform destroy
```

Si l'erreur `resource is still in use` apparaît, supprimez les security groups « Default » que Scaleway a créés dans le projet (`terraform output -raw project_id`), puis relancez :

```bash
scw instance security-group list zone=fr-par-1 project-id=<id-projet>
scw instance security-group delete <id> zone=fr-par-1
```

Faites de même dans `fr-par-2` si des VM y ont tourné. La même erreur vient aussi du nettoyage du conteneur de bascule, qui se termine après sa suppression : relancez alors `terraform destroy` une minute plus tard.

## Dépannage

| Symptôme | Cause | Action |
|---|---|---|
| `insufficient permissions: read security_groups` au premier apply | projet créé quelques secondes plus tôt, droits pas encore propagés | relancer `terraform plan` puis `terraform apply` : les ressources en échec sont remplacées |
| `need exactly one primary` au push de politique | les deux nœuds se disent primaires ou standalone : la paire n'a pas formé de cluster (réseau HA, mot de passe HA) | `get system ha status` sur chaque nœud, puis reconstruire le nœud fautif |
| `FortiGate time is out of sync` dans le WebUI du secondaire, `synchronized: no` dans `diagnose sys ntp status` | normal en FGCP : le secondaire n'interroge pas NTP, il prend l'heure du primaire | aucune ; `execute time` doit donner la même heure sur les deux nœuds |
| `out-of-sync` dans `get system ha status` juste après un apply | le secondaire n'a pas encore reçu la politique poussée | attendre une minute ; si cela dure, `diagnose sys ha checksum cluster` montre ce qui diffère |
| `stdio forwarding failed` en SSH vers un firewall | il démarre encore | attendre quelques minutes |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` en SSH vers un firewall ou un bastion | nœud reconstruit, ou nouvelle Public Gateway sur l'IP publique d'une ancienne | `ssh-keygen -R '[<ip-pgw>]:<port>'` pour le bastion, `ssh-keygen -R <ip-mgmt>` pour le nœud, puis reconnecter ; `fortigate.sh` le fait seul pour ses propres connexions |
| `Connection timed out during banner exchange` vers une VM | port fermé par la NACL du spoke | ajouter une règle `nacl_inbound` au spoke, puis appliquer |
| plus de trafic via le hub ou vers Internet après une bascule | VIP restées sur l'ancien primaire, l'appel au conteneur de bascule a échoué | lancer la ligne du primaire de `failover_commands` |
| `fortigate.sh ready` ou le push de politique échoue en SSH | le poste n'est pas dans `admin_cidrs`, ou `ssh` ou `scw` manque | corriger, puis relancer l'apply |
| `admin key never accepted: user data not applied` | FortiOS n'a pas lu ses user data : le disque avait déjà démarré, ou l'Instance a une IP publique (pas de CD-ROM NoCloud) | repartir du snapshot d'usine, sans IP publique, et reconstruire ; en console série, `diagnose debug cloudinit show` montre ce que FortiOS a lu |
| le plan échoue sur `yamldecode` ou refuse la politique | erreur de syntaxe, alias inconnu, description en double ou contenant `<`, `>` ou `&` | corriger `policy.yaml` |
| le plan refuse les CIDR | chevauchement entre `cidrs`, `spoke_supernet` et les CIDR on-prem | corriger les valeurs |
| le certificat Edge Services n'est pas émis | le CNAME du FQDN manque | créer le CNAME vers `edge_cname_target` |
| `resource is still in use` à la destruction | security group « Default » dans le projet, ou nettoyage du conteneur de bascule pas encore terminé | voir « Détruire » |
| `Command cancelled by user` sur `execute ha failover set 1` | commande passée sans terminal (`ssh ... 'cmd'`) | ouvrir une session SSH interactive et répondre `y` |

## Limites connues

- Redis, MongoDB, Kafka, OpenSearch et ClickHouse ne suivent pas le routage VPC : ils ne sont joignables que depuis leur Private Network.
- L'IAM Scaleway s'applique à un projet entier, pas à un VPC : tout opérateur du projet a les mêmes droits sur chaque spoke, sur le hub et sur les firewalls. Pour séparer des équipes, prenez la branche `hub-spoke-multi-project`.
- Les chemins Internet créés dans le projet ne passent pas par le firewall : IP publique d'instance, Load Balancer, nœuds Kapsule avec IP publique. Le contrôle passe par un inventaire (`scw instance ip list project-id=<projet>`, `scw lb list project-id=<projet>`).
- Le state contient le mot de passe `admin`, le mot de passe HA, les user data des firewalls (licences comprises) et les clés API de bascule : protégez le bucket.
- Par défaut, les règles sont en *sloppy state* : le firewall ne vérifie pas les numéros de séquence TCP, ce qui permet aux sessions de survivre à une bascule. Elles ne survivent jamais à la perte d'une Public Gateway, car l'IP publique change.
- `policy.nat_outbound` n'est pas pris en charge : le trafic Internet des spokes est traduit vers la VIP egress par la règle `[EGRESS]`.
- Dans les NACL, les retours sont ouverts en TCP et UDP sur 32768-65535 depuis toute source. Un service qui écoute sur ces ports est joignable de l'extérieur du spoke, sauf sur une instance qui porte le security group de référence du spoke. Le firewall filtre ce qui vient du hub, pas le bypass Interlink. Pas de NACL ni de routes IPv6.
- Le filtrage a trois niveaux : le firewall entre VPC, les NACL aux frontières des VPC spoke, et les security groups sur les cartes Private Network (sortie `security_group_ids`, à poser sur les instances). Tout opérateur du projet peut modifier ou détacher ces groupes : le contrôle passe par Audit Trail et un inventaire des cartes sans groupe. Un security group sur une carte Private Network y désactive l'IPv6.
- Le trafic d'Edge Services vers les Load Balancers est en HTTP, non chiffré.
- Scaleway n'expose aucun timer BGP, BFD ou DPD : la vitesse de bascule entre les deux tunnels VPN se règle sur la passerelle on-prem.
- Quand un spoke est ajouté, les VM déjà démarrées reçoivent ses routes par DHCP en une heure au plus.
- Une organisation a 512 connecteurs de peering : 127 spokes sans bypass, 85 avec.
