# Déploiement CISO Toolbox par Ansible — Ubuntu 24.04 LTS

Déploie et exploite une stack CISO Toolbox sur un hôte Ubuntu 24.04, à partir
d'une **release publiée** de la suite. Cible `docker compose`, comme la suite
publique.

## Le principe, en une phrase

`docker-compose.yml` et `nginx.conf` ne sont **jamais écrits à la main** : ils
viennent du dépôt public au tag `ciso_suite_version`. Un tag de suite décrit
une combinaison de modules testée ensemble — c'est le manifeste de
compatibilité. Monter de version, c'est changer cette variable et rejouer.

Corollaire : ne mettez pas `main` dans `ciso_suite_version`. Vous déploieriez
une composition que personne n'a validée.

## Les trois playbooks

| Playbook | Quand | Ce qu'il ajoute |
|---|---|---|
| `site.yml` | installation, et toute convergence ensuite | rien de plus : idempotent, rejouable à volonté |
| `upgrade.yml` | changement de `ciso_suite_version` | dump préalable de chaque base, contrôle des migrations et des erreurs au démarrage |
| `verify.yml` | à tout moment | contrôles seuls, n'écrit rien |

`upgrade.yml` fait tout ce que fait `site.yml`. La différence tient aux
garde-fous : il **refuse de tourner** si un dump est vide ou manquant, parce
qu'une migration Alembic ne se rejoue pas à l'envers.

---

# Déployer depuis zéro

## 1. Le nœud de contrôle

```bash
git clone <ce dépôt> && cd ansible-playbooks
ansible-galaxy collection install -r requirements.yml
```

## 2. L'inventaire

```bash
cp inventory/hosts.yml.example inventory/hosts.yml
```

Le nom donné à l'hôte dans ce fichier est structurant : `host_vars/<nom>.yml`
doit porter **exactement** le même. Un fichier dont le nom ne correspond pas
n'est jamais chargé, en silence.

## 3. Les secrets

```bash
cp group_vars/all/vault.yml.example group_vars/all/vault.yml
```

Générez chaque valeur avec `openssl rand -hex 32`, puis chiffrez :

```bash
ansible-vault encrypt group_vars/all/vault.yml
echo "<mot de passe du vault>" > .vault_pass && chmod 600 .vault_pass
```

La forme **répertoire** (`group_vars/all/`) est obligatoire. Un
`group_vars/all.vault.yml` ne serait jamais chargé : Ansible associe un
fichier au groupe portant exactement son nom, et « all.vault » n'est pas
« all ».

## 4. L'hôte

```bash
cp host_vars/example-host.yml.example host_vars/<nom-de-l-hôte>.yml
```

Ces fichiers vous appartiennent — le template ne livre qu'un `.example`,
qu'Ansible ne charge pas. Aucune mise à jour du template ne touchera votre
configuration, et vous pouvez la versionner ici sans conflit à chaque `git
pull`. À renseigner au minimum : `ciso_domain`, `ciso_deploy_dir`,
`ciso_deploy_user`, `ciso_tls_mode`, et le bloc `ciso_env`.

Ne mettez pas `main` dans `ciso_suite_version` : vous déploieriez une
composition que personne n'a validée. Un tag de suite décrit une combinaison
de modules testée ensemble — c'est le manifeste de compatibilité.

## 5. Les certificats

Voir *Installer et renouveler les certificats* ci-dessous. Le proxy ne
démarre pas sans, quel que soit le mode.

## 6. Déployer

```bash
ansible-playbook site.yml --syntax-check       # toujours avant la première fois
ansible-playbook site.yml --limit <hôte> --check --diff
ansible-playbook site.yml --limit <hôte>
```

Le mode `--check` ne couvre pas tout : le clone de la release n'y a pas lieu,
donc la copie du compose et la validation `docker compose config` sont
sautées — le playbook le dit explicitement. En revanche les contrôles d'état
(volumes de données, conteneurs existants) s'exécutent vraiment, et ce sont
les plus utiles avant un premier démarrage.

## 7. Contrôler

```bash
ansible-playbook verify.yml --limit <hôte>
```

---

# Installer et renouveler les certificats

Trois postures, selon la façon dont le certificat arrive. Le mode se choisit
avec `ciso_tls_mode`, et une valeur inconnue est rejetée explicitement.

## `provided` — fournis depuis le nœud de contrôle

Le mode d'un déploiement reproductible depuis zéro.

```bash
mkdir -p files/certs/<domaine>
cp fullchain.pem files/certs/<domaine>/cert.pem
cp privkey.pem   files/certs/<domaine>/key.pem
```

Les noms de destination sont ceux de `ciso_tls_cert_name` /
`ciso_tls_key_name` (`cert.pem` / `key.pem` par défaut) : le fichier source
doit porter le même nom que sa destination, et le répertoire correspondre
exactement à `ciso_domain`.

`files/certs/` est exclu par le `.gitignore`. Pour versionner la clé malgré
tout — utile quand plusieurs personnes déploient — chiffrez-la : le module
`copy` déchiffre les sources vaultées de façon transparente.

```bash
ansible-vault encrypt files/certs/<domaine>/key.pem
```

## `existing` — déjà sur l'hôte

Pour un certificat posé par certbot ou une PKI d'entreprise. Le playbook
vérifie sa présence et corrige ses droits, sans jamais l'écraser — le
renouvellement reste piloté par l'outil qui l'a émis.

## `selfsigned` — maquette uniquement

Génère un certificat auto-signé sur l'hôte, avec un SAN couvrant le domaine
et ses sous-domaines. Aucun navigateur ne le validera. La tâche est
idempotente par `creates` : pour en régénérer un, supprimez d'abord
l'existant.

## Rejouer les certificats seuls

```bash
ansible-playbook site.yml --tags certs --limit <hôte>
```

Copie, droits, et recréation du proxy si un fichier a changé — sans toucher
au reste de la stack. C'est la commande de chaque renouvellement.

Le playbook place les certificats en `root:root 0640`, dans un `certs/` en
`0750`. Ce n'est pas cosmétique : le proxy de la release tourne avec
`cap_drop: ALL`, donc **sans `DAC_OVERRIDE`**, et son processus root est
soumis aux bits de permission comme n'importe quel utilisateur. Un
`privkey.pem` en `0600` pour un autre compte — ce que produisent certbot et
la plupart des PKI — fait boucler nginx sur `cannot load certificate key ...
Permission denied`, proxy en `Restarting` et suite injoignable. Le rendre
propriétaire du fichier suffit, sans l'exposer aux autres comptes de l'hôte.

Seuls les droits du répertoire monté et de son contenu comptent : un montage
bind résout son chemin côté hôte au moment du montage, et le processus du
conteneur ne traverse que son propre arbre. Le mode du répertoire de
déploiement ne joue aucun rôle ici.

---

# Monter un déploiement existant de version

## 1. Choisir la cible

Changez `ciso_suite_version` dans `group_vars/all/main.yml` — ou dans le
`host_vars` de l'hôte, pour ne monter qu'un environnement.

## 2. Monter

```bash
ansible-playbook upgrade.yml --limit <hôte>
```

Ce que le playbook fait, dans l'ordre :

1. affiche la version actuellement déployée et la cible ;
2. **dump chaque base** dans `<déploiement>/dumps/`, en `0700 root` ;
3. **refuse de continuer** si un dump est vide ou manquant — un dump vide
   signale une base injoignable, et sans sauvegarde une migration ratée est
   sans retour ;
4. déploie la nouvelle release (tout ce que fait `site.yml`) ;
5. relit les logs pour tracer les **migrations Alembic** appliquées au
   démarrage ;
6. compte les `traceback` / `critical` / `refusing to start` apparus depuis
   la mise à jour et alerte s'il y en a ;
7. contrôle les sauvegardes.

## 3. Vérifier

```bash
ansible-playbook verify.yml --limit <hôte>
```

## Revenir en arrière

Il n'y a **pas** de retour arrière automatique, et c'est délibéré : les
migrations Alembic sont irréversibles. Remettre l'ancien
`ciso_suite_version` ferait tourner du code ancien sur un schéma avancé.

Le retour se fait donc par restauration : remonter l'ancienne version, puis
recharger les dumps de l'étape 2. C'est la raison d'être du garde-fou qui
refuse de démarrer sans eux.

Avant une montée qui vous inquiète, vérifiez si des migrations sont même en
jeu — si les images sont identiques, il n'y en a aucune :

```bash
ansible-playbook site.yml --tags stack --check --diff --limit <hôte>
```

---

## Deux secrets à traiter à part

`vault_encryption_key` chiffre les secrets stockés en base — configuration
SMTP, clés IA, jetons de connecteurs. **Le changer rend illisible tout ce qui
a été chiffré avec l'ancien.** Il ne se remplace pas, il se rotationne avec
l'outil dédié.

`vault_backup_cipher` chiffre le dépôt pgBackRest. **Le perdre rend les
sauvegardes irrécupérables** — c'est tout l'intérêt du chiffrement, et tout
le risque. Conservez-le ailleurs que sur la machine sauvegardée.

## Ce que le playbook contrôle, et pourquoi

Ces vérifications viennent d'une migration réelle où chacune a manqué.

**La colonne `Image` de `compose ps`.** Ni le contenu du compose ni l'absence
d'erreur dans les logs ne prouvent qu'un conteneur tourne sur la bonne image.
Un conteneur non recréé garde silencieusement l'ancienne.

**Le proxy est recréé, jamais rechargé.** `nginx.conf` est monté comme fichier
unique, donc attaché à son inode ; la plupart des éditeurs le remplacent, et
`nginx -s reload` relit alors l'ancien contenu — ou échoue.

**Un dump exploitable avant toute migration.** `upgrade.yml` refuse de
continuer si un dump est vide ou manquant : une migration Alembic ne se rejoue
pas à l'envers.

**Le premier backup complet.** Une stanza pgBackRest créée ne prouve rien.
Tant que le premier `full` n'est pas passé, l'archivage WAL tourne sans rien
sur quoi rejouer, et il n'y a aucune fenêtre de restauration.

## Images client

Une image client (add-ons propres à une organisation) remplace l'image de
suite du module :

```yaml
ciso_client_images:
  surface: "ghcr.io/cisotoolbox/ciso-surface-acme:v1.0.0"
ciso_registry_user: "mon-compte"        # + vault_registry_password
```

Le tag **et le digest** de la release sont retirés à la substitution : une
image client a ses propres empreintes, garder le digest d'origine ferait
échouer le `pull`.

## Retirer un module

`ciso_modules` pilote `PILOT_MODULES` — donc ce que Pilot propose — et les
contrôles de santé. Il ne retire **pas** les services du `docker-compose.yml`,
qui vient de la release telle quelle. Pour ne pas déployer un module, il faut
retirer ses services du compose après copie, ce que ce template ne fait pas
aujourd'hui : c'est une divergence assumée à porter côté client.

## Le moteur Docker

Par défaut, le rôle installe les paquets de la **distribution** —
`docker.io`, `docker-compose-v2`, `docker-buildx`. Sur Ubuntu 24.04 ils sont
à jour (Docker 29.x, compose 2.40.x), signés par Ubuntu et suivis par
`unattended-upgrades`, sans dépôt tiers dans la chaîne d'approvisionnement de
l'hôte.

Le dépôt officiel Docker Inc. reste disponible si une version amont précise
est nécessaire :

```yaml
ciso_docker_source: "docker-ce"
```

Sur un hôte où `docker compose version` répond déjà, **rien n'est installé**,
quelle que soit la source : `docker-ce` et `docker.io` sont en conflit, et
basculer de l'un à l'autre désinstallerait le moteur en place et arrêterait
les conteneurs en service.

## Le pare-feu de l'hôte

**Non géré par défaut** (`ciso_firewall_manage: false`). C'est une politique
d'établissement, et beaucoup d'hôtes sont déjà filtrés en amont — groupe de
sécurité, pare-feu d'hyperviseur, nftables tenus par l'exploitant. Le
template ne s'y substitue pas.

Si vous l'activez, sachez ce qu'ufw filtre réellement sur un hôte Docker :

> ufw n'arbitre **pas** les ports publiés par les conteneurs. Docker écrit ses
> propres règles — un DNAT en `nat/PREROUTING`, puis la chaîne `DOCKER`
> atteinte depuis `FORWARD`. Les règles d'ufw vivent dans `INPUT`. Un
> conteneur publiant `-p 8080:8080` reste joignable depuis le réseau **même
> avec `deny incoming` actif**.

Pour cette stack, cela veut dire que seul le **port 22** est gouverné par
ufw. Les 80/443 du proxy sont publiés par Docker : les autoriser ne change
rien, et les refuser ne les fermerait pas. Une politique « deny incoming »
qui laisse passer précisément les ports applicatifs est plus dangereuse que
pas de pare-feu du tout — elle rassure à tort.

Le vrai levier est de **ne publier que ce qui doit l'être**. Pour fermer
malgré tout un port publié, il faut la chaîne `DOCKER-USER`, que Docker
consulte avant ses propres règles et ne réécrit jamais ; ce rôle ne va pas
jusque-là, faute de connaître vos réseaux de confiance.

## Ce qui n'est pas couvert

L'obtention des certificats (ni ACME ni PKI interne — ils sont fournis), la
supervision, et la restauration. La restauration se pilote depuis Pilot, qui
a l'interface pour ça.

---

# Déplacer un déploiement existant

Les volumes Docker sont nommés d'après `COMPOSE_PROJECT_NAME`, **pas** d'après
le répertoire : déplacer un déploiement ne touche pas aux données, tant que le
nom de projet ne change pas. Les conteneurs, eux, portent des noms fixes, donc
l'ancienne stack doit être arrêtée avant que la nouvelle démarre.

```bash
# 1. arrêter l'ancienne — SANS -v, qui détruirait les volumes
cd /ancien/chemin && sudo docker compose down

# 2. déployer au nouvel emplacement
ansible-playbook site.yml --limit <hôte>

# 3. contrôler que les bases sont retrouvées (et non recréées vides)
sudo docker compose -f /opt/ciso-toolbox/docker-compose.yml exec -T pilot-db \
     psql -U pilot -tAc "select count(*) from users"
```

Le rôle refuse de démarrer si une stack tourne encore depuis un autre
répertoire, et nomme celui-ci dans le message — sans ce garde-fou, l'échec se
manifeste par un conflit de noms de conteneurs peu explicite.

Une fois la bascule vérifiée, l'ancien répertoire ne contient plus que des
fichiers de configuration régénérables. Le supprimer est sans effet sur les
données.

Reste un piège que `down` ne traite pas : un **démarrage automatique** qui
relance l'ancien répertoire. `down` supprime les conteneurs, donc leurs
politiques `restart` — mais pas une unité systemd, un cron `@reboot` ou un
`rc.local`. Ceux-là survivent et ne se manifestent qu'au prochain
redémarrage, quand deux stacks se disputent les mêmes noms de conteneurs et
les mêmes ports, des semaines après la bascule.

La release s'appuie sur `restart: unless-stopped` : la stack revient seule au
boot, sans unité ni cron. Tout mécanisme externe trouvé est donc à
désactiver, et le playbook le signale. Les unités **utilisateur** échappent à
sa recherche, vérifiez-les à la main :

```bash
systemctl --user list-unit-files --state=enabled
loginctl show-user <compte> -p Linger    # Linger=yes ⇒ démarrent sans session
```

---

Le dépôt ne contient aucun nom de client, domaine ni chemin réel : ils vivent
dans vos fichiers d'hôte et dans votre inventaire, tous deux hors du template.
