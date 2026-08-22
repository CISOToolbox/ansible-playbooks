#!/usr/bin/env bash
# Convertit un .env existant en fragments group_vars, pour reprendre un
# déploiement sous Ansible SANS régénérer aucun secret.
#
#   bash extract-env.sh /chemin/vers/.env
#
# Produit deux fichiers dans le répertoire courant :
#   ciso_env.yml         valeurs non secrètes  → à fusionner dans group_vars/all.yml
#   vault_env.yml        valeurs secrètes      → à chiffrer (ansible-vault encrypt)
#
# Les valeurs sont reprises TELLES QUELLES. C'est l'objectif : ENCRYPTION_KEY
# déchiffre ce qui est déjà en base, DB_PASSWORD est celui inscrit dans le
# volume PostgreSQL depuis l'initdb, BACKUP_CIPHER_PASS ouvre le dépôt
# pgBackRest existant. En régénérer une seule casse le déploiement.
#
# N'affiche aucun secret : seuls les NOMS des clés sont journalisés.
set -uo pipefail

SRC="${1:-.env}"
[ -r "$SRC" ] || { echo "!! fichier illisible : $SRC" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import re, sys, pathlib

src = pathlib.Path(sys.argv[1])

# Est secret tout ce qui nomme un identifiant. Le doute profite au secret :
# une valeur non sensible classée secrète ne coûte qu'un chiffrement inutile,
# l'inverse publie un mot de passe dans un dépôt git.
SECRET = re.compile(
    r"(PASSWORD|SECRET|TOKEN|_KEY$|API_KEY|CIPHER|ENCRYPTION_KEY|CLIENT_SECRET)")

# Trappe de secours dev qu'aucun code ne lit plus, mais dont le nom seul
# est une remarque d'audit assurée. Non reprise.
DROP = {"SURFACE_ALLOW_NO_AUTH"}

public, secret, dropped = {}, {}, []
for raw in src.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    key = key.strip()
    if key in DROP:
        dropped.append(key)
        continue
    (secret if SECRET.search(key) else public)[key] = value

def dump(path, root, data):
    with open(path, "w", encoding="utf-8") as f:
        f.write("---\n")
        f.write(f"{root}:\n")
        for k in sorted(data):
            v = data[k].replace('"', '\\"')
            f.write(f'  {k}: "{v}"\n')

dump("ciso_env.yml", "ciso_env", public)
dump("vault_env.yml", "vault_env", secret)

print(f"ciso_env.yml   : {len(public)} clé(s) — {', '.join(sorted(public))}")
print()
print(f"vault_env.yml  : {len(secret)} clé(s) — {', '.join(sorted(secret))}")
if dropped:
    print()
    print(f"NON reprises   : {', '.join(dropped)}")
PY

cat <<'EOF'

Suite :
  1. relire ciso_env.yml (ne doit contenir AUCUN secret)
  2. fusionner son contenu dans group_vars/all.yml
  3. mv vault_env.yml group_vars/all.vault.yml
     ansible-vault encrypt group_vars/all.vault.yml
  4. shred -u ciso_env.yml   (une fois recopié)
EOF
