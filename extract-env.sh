#!/usr/bin/env bash
# Converts an existing .env into group_vars fragments, so an existing
# deployment can be taken over by Ansible WITHOUT regenerating any secret.
#
#   bash extract-env.sh /path/to/.env
#
# Produces two files in the current directory:
#   ciso_env.yml         non-secret values  → merge into group_vars/all/main.yml
#   vault_env.yml        secret values      → encrypt (ansible-vault encrypt)
#
# Values are taken AS THEY ARE. That is the point: ENCRYPTION_KEY decrypts
# what is already in the database, DB_PASSWORD is the one written into the
# PostgreSQL volume at initdb time, BACKUP_CIPHER_PASS opens the existing
# pgBackRest repository. Regenerating a single one breaks the deployment.
#
# No secret is printed: only the NAMES of the keys are logged.
set -uo pipefail

SRC="${1:-.env}"
[ -r "$SRC" ] || { echo "!! unreadable file: $SRC" >&2; exit 1; }

python3 - "$SRC" <<'PY'
import re, sys, pathlib

src = pathlib.Path(sys.argv[1])

# Anything naming a credential is a secret. When in doubt, treat it as one:
# a non-sensitive value classified as secret costs one useless encryption,
# the opposite publishes a password in a git repository.
SECRET = re.compile(
    r"(PASSWORD|SECRET|TOKEN|_KEY$|API_KEY|CIPHER|ENCRYPTION_KEY|CLIENT_SECRET)")

# A development escape hatch no code reads any more, but whose name alone is
# a guaranteed audit finding. Not carried over.
DROP = {"SURFACE_ALLOW_NO_AUTH"}

public, secret, dropped, orphans = {}, {}, [], []
for num, raw in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        # A line without "=" is almost always the continuation of a value cut
        # by a newline. Ignoring it silently would truncate the secret with
        # nobody noticing — that happened to a JWT_SECRET in production. We
        # report it; we do not guess.
        orphans.append((num, line[:12] + "…"))
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

print(f"ciso_env.yml   : {len(public)} key(s) — {', '.join(sorted(public))}")
print()
print(f"vault_env.yml  : {len(secret)} key(s) — {', '.join(sorted(secret))}")
if dropped:
    print()
    print(f"NOT carried over : {', '.join(dropped)}")
if orphans:
    print()
    print("!! LINES WITHOUT \"=\" — a value was probably cut by a newline:")
    for num, extract in orphans:
        print(f"     line {num}: {extract}")
    print("   The key just above it is therefore TRUNCATED in the extraction.")
    print("   Fix the source .env, or regenerate the value if that is safe.")
    sys.exit(3)
PY
rc=$?
if [ "$rc" -ne 0 ]; then
    # Incomplete extraction: do not print the follow-up instructions, they
    # would suggest the result is usable.
    echo
    echo "!! Extraction ABORTED — fix the source .env and run again." >&2
    exit "$rc"
fi

cat <<'EOF'

Next:
  1. read ciso_env.yml (it must contain NO secret)
  2. merge its contents into group_vars/all/main.yml
  3. mv vault_env.yml group_vars/all/vault.yml
     ansible-vault encrypt group_vars/all/vault.yml
     NOTE: the DIRECTORY form (group_vars/all/) is mandatory. A file named
     group_vars/all.vault.yml would never be loaded — Ansible matches a file
     to the group bearing exactly its name, and "all.vault" is not "all".
  4. shred -u ciso_env.yml   (once copied over)
EOF
