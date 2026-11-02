# Landing zone Scaleway avec firewall FortiGate

Socle réseau d'une organisation Scaleway, écrit en Terraform et déployé avec Terragrunt. Un projet central, la DSI, héberge deux firewalls FortiGate en haute disponibilité FGCP actif-passif (un par zone), la sortie Internet, le VPN et Interlink. Chaque BU (unité métier) a son propre projet, créé et détruit à la demande, avec son propre state : ajouter une BU ne touche ni aux firewalls ni aux autres BU.

Tout flux qui sort d'une BU, ou qui y entre depuis l'extérieur, passe par le firewall central. Seule exception : le contournement Interlink optionnel (`hybrid_bypass`). Ce qu'une BU expose elle-même (Load Balancer, IP publique) n'est pas couvert : voir « Exposition directe » dans les [limites](docs/OPERATIONS.md#limites-connues).

<img alt="Vue d'ensemble : tout flux qui sort d'une BU traverse la paire FortiGate du hub ; les firewalls n'ont aucune IP publique." src="docs/lz-overview.svg">

Les firewalls démarrent sur l'image d'usine de Fortinet et se configurent seuls au premier démarrage, avec les user data cloud-init de leur Instance. Terraform vérifie ensuite chaque nœud par le bastion et pousse la politique.

<img alt="Premier démarrage : Terraform écrit les user data, FortiOS les lit une seule fois sur le CD-ROM NoCloud, puis fortigate.sh vérifie le nœud par le bastion et pousse la politique." src="docs/lz-provisioning.svg">

## Contenu

```text
live/root.hcl             state S3 par unité, provider (variables TG_*)
live/bus.yaml             registre des BU : index, bypass, NACL entrantes
live/dsi/terragrunt.hcl   unité DSI : firewalls, accès admin, VPN, Interlink
live/dsi/policy.yaml      politique firewall du client (modèle : policy.yaml.example)
live/dsi/observability/   relais de journaux optionnel
live/bus/<bu>/            une unité par BU (terragrunt.hcl identique pour toutes)
live/bus/<bu>/endpoints/<nom>/   exposition publique : Load Balancers, Edge Services
modules/dsi, bu, endpoint, observability   modules Terraform
docs/                     documentation
```

## Prérequis

### Outils

| Outil | Version minimale | Pourquoi |
|---|---|---|
| Terraform | 1.10 | `required_version = ">= 1.10"` dans chaque module |
| Terragrunt | version récente avec les commandes `run`, `hcl`, `find` | aucune contrainte n'est écrite dans `live/` |
| Provider `scaleway/scaleway` | 2.89 (`~> 2.89`, modules `dsi` et `observability`) | installé à l'exécution ; security groups sur les cartes Private Network |
| Provider `hashicorp/random` | 3.6 (`~> 3.6`), module `dsi` | idem |
| CLI `scw` | récente | doit être sur la machine qui déploie : elle démarre les firewalls une fois leurs cartes réseau posées et libère les VIP à la destruction |
| `ssh` | | contrôle des firewalls neufs et politique, par le bastion (Public Gateway) ; le poste doit figurer dans `admin_cidrs` |

### Droits Scaleway

- Une clé API d'organisation : elle crée projets, applications, politiques et clés IAM, et gère VPC, Instances, Block Storage, IPAM, Public Gateways, VPN, Load Balancers et Edge Services. Les connecteurs de peering du Hub sont créés dans le projet DSI depuis chaque BU, d'où la clé d'organisation. Une clé d'administrateur convient.
- Un bucket Object Storage privé et versionné pour les states : `scw object bucket update <bucket> enable-versioning=true region=fr-par`. Le state DSI contient des secrets : réservez le bucket aux opérateurs.
- Les zones `fr-par-1` et `fr-par-2` pour les firewalls (`fr-par-3` n'a ni Public Gateway ni Load Balancer).

### Image FortiGate et licences

Le qcow2 FortiOS KVM de Fortinet s'importe tel quel, sans modification (étape 1 du déploiement). Chaque nœud a sa propre licence FortiGate-VM (BYOL, fichier `.lic` jamais versionné).

### Variables d'environnement

Ne les versionnez jamais.

```bash
export SCW_ACCESS_KEY=<clé> SCW_SECRET_KEY=<secret> SCW_DEFAULT_ORGANIZATION_ID=<id-organisation>
export AWS_ACCESS_KEY_ID=$SCW_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$SCW_SECRET_KEY   # accès au bucket du state
export TG_STATE_BUCKET=<bucket-du-state>
export TG_REGION=fr-par TG_ZONE=fr-par-1   # facultatif : ce sont les défauts
```

`TG_REGION` est la région du bucket et des zones des firewalls.

## Déploiement

Les commandes se lancent depuis le dossier de ce README.

1. Importer le qcow2 FortiOS KVM d'usine (le `fortios.qcow2` du zip Fortinet, déposé dans un bucket de la région), un snapshot par zone :

   ```bash
   scw block snapshot import-from-object-storage zone=fr-par-1 bucket=<bucket> key=fortios.qcow2 name=fortios-<version>
   scw block snapshot import-from-object-storage zone=fr-par-2 bucket=<bucket> key=fortios.qcow2 name=fortios-<version>
   ```

   Les deux identifiants, au format `<zone>/<uuid>`, sont les `snapshot_id` de `firewall.nodes`. Ne démarrez jamais une Instance sur ces snapshots à la main : un disque qui a déjà démarré ignore ses user data.

2. Configurer :
   - `live/dsi/terragrunt.hcl` : `admin_cidrs` (votre IP publique en `/32`), `admin_ssh_public_keys`, les deux `snapshot_id` et `license_file` de `firewall.nodes` ; `vpn` et `interlink` si besoin ;
   - `live/bus.yaml` : vos BU ; remplacez les exemples `live/bus/genomic` et `live/bus/genomic/endpoints/web` par les vôtres ;
   - `live/dsi/policy.yaml` (facultatif) : règles propres au client, à partir de `policy.yaml.example`.

   Toutes les options : [docs/CONFIGURATION.md](docs/CONFIGURATION.md). Vérification de la syntaxe (les avertissements `has no outputs, but mock outputs provided` sont normaux avant le premier apply) :

   ```bash
   cd live && terragrunt hcl fmt --check && terragrunt hcl validate && terragrunt find
   ```

3. Déployer la DSI :

   ```bash
   terragrunt plan --working-dir live/dsi
   terragrunt apply --working-dir live/dsi
   ```

4. Récupérer les accès d'administration (SSH par le bastion, WebUI par tunnel `ssh -L`) et le mot de passe `admin` :

   ```bash
   terragrunt output -json access --working-dir live/dsi
   terragrunt output -raw fw_admin_password --working-dir live/dsi
   ```

   L'apply attend que les deux nœuds soient prêts (environ 3 min 30), puis pousse la politique. Tant qu'un nœud démarre, le SSH répond `stdio forwarding failed`.

5. Déployer les BU et les expositions (toutes les unités, dans l'ordre des dépendances) :

   ```bash
   cd live && terragrunt run --all -- apply
   ```

   Cette commande inclut `live/dsi/observability`, le relais de journaux (firewalls → Alloy → Cockpit) : supprimez ce dossier si vous ne le voulez pas ([modules/observability/README.md](modules/observability/README.md)). Pour une seule unité :

   ```bash
   terragrunt apply --working-dir live/bus/<bu>
   terragrunt apply --working-dir live/bus/<bu>/endpoints/<nom>
   ```

   Si une exposition utilise Edge Services, créez un CNAME de chaque FQDN vers la sortie `edge_cname_target` de l'unité, sans quoi le certificat n'est pas émis.

6. Vérifier : `terragrunt output --working-dir live/bus/<bu>` (adresses et projet de la BU) et `scw vpc vpc-connector list region=fr-par` (tous les connecteurs doivent être `peered`).

### Tests hors ligne

Ils n'appellent pas Scaleway. Un module à la fois :

```bash
terraform -chdir=modules/dsi init -backend=false && terraform -chdir=modules/dsi test
```

Même commande pour `bu`, `endpoint` et `observability`.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) : flux, filtrage, administration, premier démarrage, bascule.
- [docs/OPERATIONS.md](docs/OPERATIONS.md) : ajouter une BU, changer la politique, reconstruire un firewall, détruire, dépannage, limites.
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) : toutes les options.
- [modules/observability/README.md](modules/observability/README.md) : relais de journaux et alertes.
