# Configuration

Chaque unité Terragrunt de `live/` porte sa configuration dans son bloc `inputs`. Deux fichiers partagés complètent : `live/bus.yaml` (registre des BU) et `live/dsi/policy.yaml` (politique du firewall). Pour déployer, voir [Déploiement](../README.md#déploiement).

Une option sans défaut est obligatoire. `null` signifie « valeur par défaut du module ». Les défauts viennent de `modules/*/variables.tf`.

**Application d'un changement**

- **Infra** : l'apply modifie les ressources Scaleway, sans toucher aux firewalls.
- **À chaud** : la politique est poussée sur le primaire FGCP, qui synchronise le secondaire (aucun redémarrage).
- **Reconstruction** : le changement n'atteint un nœud qu'à sa création ; reconstruisez-le, un nœud après l'autre ([Exploitation](OPERATIONS.md)).

## Unités et fichiers

| Fichier | Rôle |
|---|---|
| `live/root.hcl` | backend et provider communs, inclus par toutes les unités |
| `live/dsi/terragrunt.hcl` | hub de la DSI : firewalls, VPN, Interlink |
| `live/dsi/policy.yaml` | politique du firewall, optionnelle (modèle : `policy.yaml.example`) |
| `live/bus.yaml` | registre des BU : index, bypass Interlink, NACL |
| `live/bus/<bu>/terragrunt.hcl` | une BU ; son nom est celui du dossier |
| `live/bus/<bu>/endpoints/<nom>/terragrunt.hcl` | exposition publique d'une BU (ou `live/dsi/endpoints/<nom>/` pour la DSI) |
| `live/dsi/observability/terragrunt.hcl` | relais de journaux, optionnel |

## Environnement et backend

Lues par `live/root.hcl`. Un state S3 par unité, clé `landing-zone/<chemin de l'unité>/terraform.tfstate`, verrou natif.

| Variable | Défaut | Effet |
|---|---|---|
| `SCW_ACCESS_KEY`, `SCW_SECRET_KEY` | obligatoire | clé API d'organisation, lue par le provider |
| `SCW_DEFAULT_ORGANIZATION_ID` | obligatoire | organisation qui reçoit les projets |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | obligatoire | clés Object Storage du bucket des states |
| `TG_STATE_BUCKET` | obligatoire | bucket des states |
| `TG_REGION` | `fr-par` | région du provider et du bucket |
| `TG_ZONE` | `fr-par-1` | zone par défaut du provider |

## live/dsi/terragrunt.hcl

```hcl
inputs = {
  admin_cidrs           = ["203.0.113.10/32"]
  admin_ssh_public_keys = ["ssh-ed25519 AAAA... admin@dsi"]

  firewall = {
    nodes = {
      fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid du snapshot>" }
      fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid du snapshot>" }
    }
  }
}
```

Le fichier fourni contient aussi `name = "dsi-hub"`, le bloc `locals` qui lit `policy.yaml`, et des blocs `vpn`, `interlink` et `edge_services_plan` commentés.

| Variable | Défaut | Effet | Application |
|---|---|---|---|
| `name` | `dsi-hub` | préfixe des ressources et nom du projet créé. Ne pas le changer après déploiement | — |
| `admin_cidrs` | obligatoire | IP publiques autorisées sur le bastion SSH des Public Gateways. `0.0.0.0/0` est refusé. Le poste qui applique doit en faire partie (contrôle des nœuds neufs et politique passent par le bastion) | infra |
| `admin_ssh_public_keys` | obligatoire | clés OpenSSH (ed25519, rsa, ecdsa) du bastion et du compte `admin` des firewalls (les 3 premières) | bastion : infra ; firewalls : reconstruction |
| `firewall` | obligatoire | voir [firewall](#firewall) | reconstruction |
| `policy` | `{}` | fourni par `policy.yaml`, voir [policy.yaml](#livedsipolicyyaml) | à chaud |
| `edge_services_plan` | `null` | abonnement Edge Services du projet DSI (ex. `starter`), requis par les expositions DSI avec `edge` | infra |
| `vpn` | `null` | VPN site à site inspecté par le firewall, voir [vpn](#vpn) | infra |
| `interlink` | `null` | lien sans inspection vers le VPC Hybrid, voir [interlink](#interlink) | infra |

### firewall

Paire FortiGate-VM FGCP, sans IP publique. Chaque nœud (exactement `fw1` et `fw2`) a une `zone` (`fr-par-1` ou `fr-par-2`), **une seule** source et, en option, sa licence :

- `snapshot_id` : `<zone>/<uuid>` du snapshot du qcow2 d'usine ([déploiement, étape 1](../README.md#déploiement)), cas normal ;
- `image` : image de ce qcow2, ou identifiant d'image local à la zone.

Jamais un disque qui a déjà démarré : FortiOS ne lit ses user data cloud-init qu'au premier démarrage d'un disque.

`license_file` : fichier de licence FortiGate-VM (`.lic`, BYOL) du nœud, posé par ses user data cloud-init au premier démarrage. Une licence par nœud ; ne versionnez pas ces fichiers (ils sont ignorés par git).

Les zones des nœuds fixent aussi celles des Public Gateways et des passerelles VPN.

| Champ | Défaut | Effet | Application |
|---|---|---|---|
| `nodes` | obligatoire | `fw1` et `fw2`, chacun avec `zone`, une source et `license_file` | reconstruction, un nœud à la fois |
| `instance_type` | `POP2-2C-8G` | taille des firewalls | reconstruction |
| `syslog` | `[]` | 4 collecteurs syslog distants au plus : `host` (IPv4 ou nom), `port` (défaut `514`), `transport` (`udp` ou `tcp`, défaut `udp`) | reconstruction |

Le mot de passe du compte `admin` est généré par Terraform : sortie `fw_admin_password`.

```hcl
firewall = {
  syslog = [{ host = "10.0.4.5", port = 514, transport = "udp" }]
  nodes = {
    fw1 = { zone = "fr-par-1", snapshot_id = "fr-par-1/<uuid>", license_file = "licenses/fw1.lic" }
    fw2 = { zone = "fr-par-2", snapshot_id = "fr-par-2/<uuid>", license_file = "licenses/fw2.lic" }
  }
}
```

### vpn

Un tunnel IPsec avec BGP par zone de firewall.

| Champ | Défaut | Effet | Application |
|---|---|---|---|
| `customer_gateway_ip` | obligatoire | IP publique du routeur on-prem | infra |
| `customer_asn` | obligatoire | numéro AS BGP de l'on-prem | infra |
| `onprem_cidrs` | obligatoire | réseaux on-prem joignables par le VPN | infra et à chaud |

### interlink

Lien vers le VPC Hybrid, atteint seulement par les BU Private avec `hybrid_bypass`, sans firewall.

```hcl
interlink = {
  pop_id         = "fr-par/<uuid du PoP>"
  bandwidth_mbps = 1000
  partner_id     = "fr-par/<uuid du partenaire>"
  onprem_cidrs   = ["10.10.0.0/16"]
}
```

| Champ | Défaut | Effet |
|---|---|---|
| `pop_id`, `bandwidth_mbps`, `onprem_cidrs` | obligatoires | PoP, débit, réseaux on-prem |
| `partner_id` | `null` | lien hébergé par un partenaire |
| `connection_id` | `null` | lien en propre. Exactement un de `partner_id` ou `connection_id` |
| `peer_asn`, `vlan` | `null` | lien en propre uniquement |

La clé d'appairage à remettre au partenaire est dans la sortie `interlink` (sensible : `terragrunt output -json interlink`).

## live/dsi/policy.yaml

Optionnel. Modèle : `live/dsi/policy.yaml.example`. Absent, vide ou entièrement commenté, il donne une politique vide. Une erreur de syntaxe fait échouer le plan. Application à chaud : les règles sont poussées en direct sur le primaire FGCP, et un réglage fait dans le WebUI est écrasé au prochain push.

```yaml
aliases:
  BU_GENOMIC: ["10.96.8.0/21"] # Private de la BU d'index 1
  BU_HR: ["10.96.16.0/21"]     # Private de la BU d'index 2
rules:
  - description: "Genomic reaches HR over HTTPS"
    action: pass
    source: BU_GENOMIC
    destination: BU_HR
    protocol: tcp
    port: 443
```

Les CIDR d'une BU : `terragrunt output cidrs --working-dir live/bus/<bu>`.

**`aliases`** : nom (lettres, chiffres, `_`, 32 caractères au plus, pas un alias intégré) vers une liste non vide de CIDR.

**`rules`** :

| Champ | Défaut | Valeurs |
|---|---|---|
| `description` | obligatoire | unique, sans `<`, `>` ni `&` |
| `action` | obligatoire | `pass` ou `block` |
| `source`, `destination` | obligatoire | `any`, un CIDR, un alias intégré ou un alias à vous |
| `protocol` | `any` | `any`, `tcp`, `udp`, `icmp` |
| `port`, `port_end` | aucun | 1 à 65535, avec `tcp` ou `udp` ; `port_end` ouvre une plage |
| `interface` | `hub` | `hub` (trafic des BU, de l'on-prem et des LB de la DSI) ou `egress` |
| `state` | `sloppy` | `sloppy` (pas de contrôle des numéros de séquence TCP : les sessions survivent mieux à une bascule) ou `keep` |

**`nat_outbound`** : non pris en charge sur FortiGate, doit rester vide (le plan échoue sinon). Le trafic Internet des BU est traduit vers la VIP egress par la règle `[EGRESS]`.

**Alias intégrés** : `BU_NETS` (toutes les BU), `DSI_EGRESS_NET` (réseau Egress de la DSI), `ONPREM_VPN` (on-prem du VPN), `EGRESS_PGWS` (les deux Public Gateways), `internal_nets` (RFC 1918, BU, DSI, on-prem VPN et Interlink).

**Ordre d'évaluation.** Première règle qui correspond : **vos règles dans l'ordre du fichier**, `[EW]` (blocage entre BU), `[DSI]`, `[VPN]`, `[EGRESS]` (sortie Internet, non journalisée), puis refus. Vos règles passent avant `[EW]` : une exception au blocage inter-BU s'écrit telle quelle. Pensez aussi au `nacl_inbound` de la BU cible.

## live/bus.yaml

Registre des BU : une entrée par BU, clé = nom de la BU.

```yaml
genomic:
  index: 1
  hybrid_bypass: true
  edge_services_plan: starter
  nacl_inbound:
    - to: private
      source: 10.0.4.0/24
      port: 8080
      description: DSI load balancers to genomic backends
```

| Champ | Défaut | Effet | Application |
|---|---|---|---|
| `index` | obligatoire | entier unique de 0 à 1023, **permanent**. Fixe le Pub (/22 dans `10.64.0.0/12`) et le Private (/21 dans `10.96.0.0/11`). Ne jamais le changer pour une BU en service ; garder celui d'une BU supprimée réservé jusqu'à la suppression de son projet | — |
| `hybrid_bypass` | `false` | relie le VPC Private au VPC Hybrid (Interlink, sans firewall). Sans effet si la DSI n'a pas d'`interlink`. Ajoute 2 connecteurs de peering | infra |
| `edge_services_plan` | `null` | abonnement Edge Services du projet BU (`starter`, `professional`…), nécessaire aux expositions avec `edge` | infra |
| `nacl_inbound` | `[]` | flux autorisés **vers** la BU depuis l'extérieur (on-prem, LB de la DSI, autre BU), dans les NACL et dans les security groups de référence | infra |
| `intra_pn` | `true` | les security groups de référence acceptent le trafic à l'intérieur de chaque Private Network ; `false` le ferme (les workloads ont alors besoin de leurs propres groupes pour se parler) | infra |

Élément de `nacl_inbound` :

| Champ | Défaut | Valeurs |
|---|---|---|
| `to` | obligatoire | `pub` ou `private` |
| `source` | obligatoire | CIDR |
| `protocol` | `TCP` | `ANY`, `TCP`, `UDP`, `ICMP` |
| `port`, `port_end` | `0` (tous les ports) ; fin = `port` | port, ou plage avec `port_end` |
| `description` | `Inbound from <source>` | texte libre |

**Sécurité des NACL.** Sans état, elles refusent par défaut. Elles acceptent toujours le trafic sortant, Pub vers Private, ICMP, et les retours TCP et UDP sur les ports 32768-65535 **depuis toute source** : un service qui écoute sur un port de cette plage est joignable de l'extérieur de la BU. Ce qui vient du Hub (autre BU, on-prem par VPN, DSI) reste filtré par le firewall ; seuls le bypass Interlink et Pub vers Private ne le sont pas. Le trafic à l'intérieur d'un Private Network n'est jamais filtré par les NACL.

**Security groups de référence.** L'unité BU crée, par tier (`pub`, `private`) et par zone des firewalls, un security group avec état, filtré par l'hyperviseur, à poser sur les cartes Private Network des instances de la BU (sortie `security_group_ids`). Il refuse tout en entrée sauf : ICMP, le Private Network lui-même (`intra_pn`), Pub vers Private, le bypass Interlink et `nacl_inbound`. Il ferme ce que les NACL laissent ouvert : un service sur un port 32768-65535 n'est plus joignable de l'extérieur, et le trafic interne au Private Network peut être filtré. La BU peut modifier ou détacher ces groupes (`InstancesFullAccess`) : les NACL restent la barrière imposée par la DSI. Ne s'applique qu'aux instances ; nœuds Kapsule, Load Balancers et bases managées restent sous les seules NACL. Un security group sur une carte Private Network y désactive l'autoconfiguration IPv6.

## Unité BU

`live/bus/<bu>/terragrunt.hcl` est identique pour toutes les BU. Son nom est celui du dossier, qui doit exister dans `bus.yaml` (2 à 24 caractères : minuscules, chiffres et tirets, commence par une lettre).

```hcl
include "root" {
  path = find_in_parent_folders("root.hcl")
}

include "bu" {
  path = find_in_parent_folders("bu.hcl")
}
```

Les droits du groupe IAM `bu-<nom>` se fixent dans un bloc `inputs` de cette unité :

```hcl
inputs = {
  iam_permission_sets = [
    "BlockStorageFullAccess",
    "RelationalDatabasesFullAccess",
    "ObjectStorageFullAccess",
    "PrivateNetworksReadOnly",
    "VPCReadOnly",
  ]
}
```

Défaut : `InstancesFullAccess`, `BlockStorageFullAccess`, `LoadBalancersFullAccess`, `EdgeServicesFullAccess`, `KubernetesFullAccess`, `RelationalDatabasesFullAccess`, `ObjectStorageFullAccess`, `SecretManagerFullAccess`, `ObservabilityFullAccess`, `IPAMFullAccess`, `PrivateNetworksReadOnly`, `VPCReadOnly`. Application : infra.

**Sécurité IAM.** Retirer `InstancesFullAccess`, `LoadBalancersFullAccess` ou `KubernetesFullAccess` ferme l'exposition directe vers Internet. Aucun jeu ne donne de droit sur le réseau (VPC, passerelles, VPN, Interlink).

## Expositions

Dossier `live/bus/<bu>/endpoints/<nom>/` (ou `live/dsi/endpoints/<nom>/`) avec ce fichier. Il se rattache au réseau Pub de la BU, ou au réseau Egress pour la DSI. Les ressources s'appellent `<bu>-<nom>`.

```hcl
include "root"     { path = find_in_parent_folders("root.hcl") }
include "endpoint" { path = find_in_parent_folders("endpoint.hcl") }

inputs = {
  config = {
    zones   = ["fr-par-1", "fr-par-2"]
    backend = { server_ips = ["10.96.8.10", "10.96.8.11"], port = 8080, health_check_uri = "/healthz" }
    edge    = { fqdns = ["app.example.com"] }   # retirer pour un LB seul
  }
}
```

| Champ de `config` | Défaut | Effet |
|---|---|---|
| `zones` | `["fr-par-1", "fr-par-2"]` | un Load Balancer par zone |
| `backend.server_ips` | obligatoire | IP des serveurs, dans Pub ou Private |
| `backend.port` | obligatoire | port des serveurs |
| `backend.protocol` | `http` | `http` ou `tcp` |
| `backend.health_check_uri` | `null` | chemin du contrôle HTTP ; `null` donne un contrôle TCP |
| `frontend_port` | `80` | port d'écoute des LB |
| `lb_type` | `LB-S` | taille des Load Balancers |
| `edge.fqdns` | obligatoire si `edge` | noms de domaine servis par Edge Services |
| `edge.waf_mode` | `enable` | `enable`, `log_only` ou `disable` |
| `edge.paranoia_level` | `1` | niveau de paranoïa du WAF |

Sans `edge`, les LB sont ouverts directement. Avec `edge`, ils n'acceptent que les IP d'Edge Services. Application : infra.

## Relais d'observabilité

Optionnel, dans `live/dsi/observability/`. Il reçoit le syslog des firewalls et le pousse dans Cockpit ; fonctionnement et activation dans [modules/observability/README.md](../modules/observability/README.md). Réseau, bastion, clés SSH, nom et zone viennent de la DSI : ne les recopiez pas. Options à ajouter dans son bloc `inputs` :

| Variable | Défaut | Effet |
|---|---|---|
| `host` | `5` | numéro d'hôte du relais dans le réseau Egress ; doit être libre |
| `retention_days` | `31` | rétention des journaux dans Cockpit |
| `instance_type` | `PRO2-XXS` | type de la VM relais |
| `disk_size_gb` | `20` | taille du disque |
| `alloy_version` | `null` | version du paquet apt Grafana Alloy ; `null` installe la dernière stable |
| `keep_filterlog` | `false` | envoie aussi le journal de paquets (`filterlog`), très volumineux |

Application : infra. Reporter la sortie `syslog_target` dans `firewall.syslog` de la DSI, puis reconstruire les nœuds.

## Options avancées

### DSI (`live/dsi/terragrunt.hcl`)

| Variable | Défaut | Effet | Application |
|---|---|---|---|
| `project_id` | `null` | projet existant où déployer ; `null` crée un projet `name` | infra |
| `tags` | `["landing-zone", "dsi"]` | tags des ressources | infra |
| `cidrs` | mgmt `10.0.6.0/24`, egress `10.0.4.0/24`, sync `10.255.0.0/24`, hub `172.16.0.0/24`, hybrid `10.0.5.0/24` | plan d'adressage de la DSI ; ne doit chevaucher ni `bu_supernet`, ni l'on-prem. `mgmt` : VPC isolé de management, où les Public Gateways (masquerade, route par défaut, bastion) donnent aux nœuds l'accès SSH et Internet ; `sync` : réseau HA (heartbeat FGCP unicast) | reconstruction |
| `bu_supernet` | `10.64.0.0/10` | bloc qui contient toutes les BU (/10 ou plus large) | non modifiable en service |
| `hub_vrouter_ip` | `169.254.169.254` | prochain saut des routes vers le routeur du Hub | reconstruction |
| `egress.gateway_type` | `VPC-GW-S` | type des Public Gateways (bande passante) | infra |
| `egress.pgw_hosts` | `a = 2`, `b = 3` | numéros d'hôte des Public Gateways dans le réseau Egress | reconstruction |
| `firewall.hosts` | `data = 10`, `fw1 = 11`, `fw2 = 12` | numéros d'hôte : VIP de données (Hub et Egress), nœuds. Les 5 numéros (avec `egress.pgw_hosts`) sont distincts | reconstruction |
| `firewall.disk` | `size_gb = 10`, `iops = 5000` | volume des firewalls | reconstruction |
| `firewall.system` | `timezone = "Europe/Paris"`, `dns = ["1.1.1.1", "1.0.0.1"]`, `ntp = ["0.pool.ntp.org", "1.pool.ntp.org"]` | fuseau, DNS et NTP des firewalls | reconstruction |
| `firewall.gateway_monitors` | `a = "1.0.0.1"`, `b = "9.9.9.9"` | cibles du link monitor, une par Public Gateway | reconstruction |
| `firewall.ha` | `arps = 60`, `arps_interval = 1` | ARP gratuits émis par un nouveau primaire (1-60, intervalle 1-20 s) | reconstruction |
| `vpn.gateway_type` | `VGW-S` | taille des passerelles VPN | infra |
| `vpn.ciphers` | IKE et ESP : `aes256`, `sha256`, `modp2048` | propositions IKE (phase 1) et ESP (phase 2) : `encryption`, `integrity`, `dh_group` | infra |
| `vpn.bgp_links` | a : `169.254.100.1/30` (Scaleway), `.2/30` (on-prem) ; b : `.5/30`, `.6/30` | adresses BGP `/30` des deux tunnels : `scaleway` et `onprem` | infra |

## Sorties utiles

`terragrunt output <nom> --working-dir <unité>` (les sorties `project_id`, `bu_contract`, `endpoint_target` et `observability_target` servent aux autres unités) :

| Unité | Sorties | Contenu |
|---|---|---|
| `live/dsi` | `firewall` | VIP de données et, par nœud, adresses, zone et identifiant |
| `live/dsi` | `egress_public_ips` | les deux IP publiques de sortie (allow-lists) |
| `live/dsi` | `access` | par nœud : SSH par le bastion (`ssh -J`) et tunnel `ssh -L` pour le WebUI |
| `live/dsi` | `failover_commands` | par nœud : déplacement manuel des VIP dans l'IPAM, secours de la fonction de bascule ; lancer la ligne du primaire FGCP |
| `live/dsi` | `vpn`, `interlink` | IP des passerelles, BGP, `psk_secret_id` ; clé d'appairage (sensible : `-json`) |
| `live/dsi` | `fw_admin_password` | mot de passe `admin` généré (sensible : `-raw`) |
| `live/bus/<bu>` | `cidrs`, `private_network_ids`, `security_group_ids`, `iam_group_id` | plan d'adressage et identifiants de la BU |
| `live/bus/<bu>/endpoints/<nom>` | `lb_public_ips`, `edge_cname_target` | IP des LB par zone ; cible du CNAME de chaque FQDN |
| `live/dsi/observability` | `syslog_target`, `grafana_url`, `access` | collecteur pour `firewall.syslog`, Grafana, accès SSH |
