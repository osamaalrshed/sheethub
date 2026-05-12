"""
NocoDB workspace setup script.

What it does:
  1. Waits for NocoDB to be reachable.
  2. Signs in as the admin (NC_ADMIN_EMAIL / NC_ADMIN_PASSWORD from .env).
  3. Creates three bases — Finance, Sales, Operations — each connected to the
     business_inputs PostgreSQL database, scoped to one schema.
  4. Creates three test users and assigns each as Editor on their base.

Tested against NocoDB API v1 (self-hosted, ≤ v2026.05.0).
If future releases break the base-creation format, a MANUAL FALLBACK section
is printed so you can complete those steps in the UI.

Prerequisites:
  - Docker Compose stack is running: docker compose up -d
  - NocoDB has started (the script waits up to 3 minutes).
  - .env file is present in the parent directory (or env vars are exported).

Usage:
    cd setup
    pip install -r requirements.txt
    python setup_nocodb.py

    # or from the project root:
    python setup/setup_nocodb.py
"""

import json
import os
import sys
import time
from pathlib import Path

import requests
from dotenv import load_dotenv

# ── Load env ──────────────────────────────────────────────────────────────────
# Try .env in parent directory (project root) first, then current directory.
_env_paths = [Path(__file__).parent.parent / ".env", Path(".env")]
for _p in _env_paths:
    if _p.exists():
        load_dotenv(_p)
        break

NOCODB_URL       = os.environ.get("NOCODB_URL", "http://localhost:8080").rstrip("/")
ADMIN_EMAIL      = os.environ.get("NC_ADMIN_EMAIL", "")
ADMIN_PASSWORD   = os.environ.get("NC_ADMIN_PASSWORD", "")
TEST_PASSWORD    = os.environ.get("TEST_USER_PASSWORD", "")

PG_HOST          = os.environ.get("PG_HOST_FROM_NOCODB", "postgres")
PG_PORT          = int(os.environ.get("PG_PORT", 5432))
PG_USER          = os.environ.get("POSTGRES_NOCODB_USER", "nocodb_user")
PG_PASSWORD      = os.environ.get("POSTGRES_NOCODB_PASSWORD", "")

BASES = [
    {"title": "Finance",    "schema": "finance",    "user_email": "finance@test.local"},
    {"title": "Sales",      "schema": "sales",      "user_email": "sales@test.local"},
    {"title": "Operations", "schema": "operations", "user_email": "ops@test.local"},
]


# ── Helpers ───────────────────────────────────────────────────────────────────

def _headers(token: str) -> dict:
    return {"xc-auth": token, "Content-Type": "application/json"}


def _check_env() -> None:
    missing = [k for k, v in {
        "NC_ADMIN_EMAIL":           ADMIN_EMAIL,
        "NC_ADMIN_PASSWORD":        ADMIN_PASSWORD,
        "TEST_USER_PASSWORD":       TEST_PASSWORD,
        "POSTGRES_NOCODB_PASSWORD": PG_PASSWORD,
    }.items() if not v]
    placeholder = [k for k, v in {
        "TEST_USER_PASSWORD": TEST_PASSWORD,
    }.items() if v.startswith("CHANGE_ME")]
    missing += placeholder
    if missing:
        print(f"[ERROR] Missing or placeholder env vars: {', '.join(missing)}")
        print("        Edit your .env file and try again.")
        sys.exit(1)


def wait_for_nocodb(timeout: int = 180) -> None:
    url = f"{NOCODB_URL}/api/v1/health"
    deadline = time.monotonic() + timeout
    print(f"Waiting for NocoDB at {NOCODB_URL} …", end="", flush=True)
    while time.monotonic() < deadline:
        try:
            r = requests.get(url, timeout=5)
            if r.status_code == 200:
                print(" ready.")
                return
        except requests.RequestException:
            pass
        print(".", end="", flush=True)
        time.sleep(5)
    print()
    print(f"[ERROR] NocoDB did not become ready within {timeout}s.")
    print("        Is the stack running?  docker compose up -d")
    sys.exit(1)


def sign_in(email: str, password: str) -> str:
    r = requests.post(
        f"{NOCODB_URL}/api/v1/auth/user/signin",
        json={"email": email, "password": password},
        timeout=15,
    )
    if r.status_code != 200:
        print(f"[ERROR] Admin sign-in failed ({r.status_code}): {r.text}")
        sys.exit(1)
    token = r.json().get("token")
    if not token:
        print(f"[ERROR] No token in sign-in response: {r.text}")
        sys.exit(1)
    print(f"Signed in as {email}")
    return token


# ── User management ───────────────────────────────────────────────────────────

def create_user(token: str, email: str, password: str) -> str | None:
    """Sign up a test user. Returns the user ID, or None on failure."""
    r = requests.post(
        f"{NOCODB_URL}/api/v1/auth/user/signup",
        json={"email": email, "password": password},
        timeout=15,
    )
    if r.status_code in (200, 201):
        user_id = r.json().get("user", {}).get("id") or r.json().get("id")
        print(f"  Created user: {email}")
        return user_id

    # 400 "already exists" — sign in to get id
    if r.status_code == 400 and "already" in r.text.lower():
        s = requests.post(
            f"{NOCODB_URL}/api/v1/auth/user/signin",
            json={"email": email, "password": password},
            timeout=15,
        )
        if s.status_code == 200:
            user_id = s.json().get("user", {}).get("id")
            print(f"  User already exists: {email}")
            return user_id

    print(f"  [WARN] Could not create user {email} ({r.status_code}): {r.text[:200]}")
    return None


def get_user_id_by_email(token: str, email: str) -> str | None:
    """Look up a user id from the super-admin user list."""
    r = requests.get(
        f"{NOCODB_URL}/api/v1/db/meta/users",
        headers=_headers(token),
        timeout=15,
    )
    if r.status_code != 200:
        return None
    for user in r.json().get("list", []):
        if user.get("email") == email:
            return user.get("id")
    return None


# ── Base / project management ─────────────────────────────────────────────────

def create_external_base(token: str, title: str, schema: str) -> str | None:
    """
    Create a NocoDB base that points at the business_inputs PostgreSQL database,
    filtered to a single schema.

    The v1 API body format below is the best-documented form for self-hosted
    NocoDB.  If the call returns 404 or 422, fall through to manual instructions.
    """
    payload = {
        "title": title,
        "bases": [
            {
                "alias": title,
                "type": "pg",
                "is_meta": False,
                "config": {
                    "client": "pg",
                    "connection": {
                        "host":     PG_HOST,
                        "port":     str(PG_PORT),
                        "user":     PG_USER,
                        "password": PG_PASSWORD,
                        "database": "business_inputs",
                    },
                    "searchPath": [schema],
                },
                "inflection_column": "camelize",
                "inflection_table": "camelize",
            }
        ],
    }

    r = requests.post(
        f"{NOCODB_URL}/api/v1/db/meta/projects/",
        headers=_headers(token),
        json=payload,
        timeout=30,
    )
    if r.status_code in (200, 201):
        base_id = r.json().get("id")
        print(f"  Created base '{title}' (id={base_id}) — schema: {schema}")
        return base_id

    print(f"  [WARN] Base '{title}' creation returned {r.status_code}: {r.text[:300]}")
    return None


def list_bases(token: str) -> list[dict]:
    r = requests.get(
        f"{NOCODB_URL}/api/v1/db/meta/projects/",
        headers=_headers(token),
        timeout=15,
    )
    if r.status_code == 200:
        return r.json().get("list", [])
    return []


def invite_user_to_base(token: str, base_id: str, email: str, role: str = "editor") -> bool:
    r = requests.post(
        f"{NOCODB_URL}/api/v1/db/meta/projects/{base_id}/users",
        headers=_headers(token),
        json={"email": email, "roles": role},
        timeout=15,
    )
    if r.status_code in (200, 201):
        print(f"    Invited {email} as {role} on base {base_id}")
        return True
    print(f"    [WARN] Could not invite {email} ({r.status_code}): {r.text[:200]}")
    return False


# ── Manual-fallback printer ───────────────────────────────────────────────────

def print_manual_steps(failed_bases: list[dict]) -> None:
    if not failed_bases:
        return
    print()
    print("=" * 65)
    print("MANUAL STEPS REQUIRED")
    print("=" * 65)
    print("The following bases could not be created automatically.")
    print("Complete them in the NocoDB UI at:", NOCODB_URL)
    print()
    for b in failed_bases:
        print(f"  Base: {b['title']}")
        print(f"  1. Click '+ New Base' (or '+ New Project')")
        print(f"  2. Choose 'Connect External Database'")
        print(f"  3. Enter:")
        print(f"       Host:     {PG_HOST}   (from inside Docker: postgres)")
        print(f"       Port:     {PG_PORT}")
        print(f"       Database: business_inputs")
        print(f"       Schema:   {b['schema']}")
        print(f"       User:     {PG_USER}")
        print(f"       Password: (from POSTGRES_NOCODB_PASSWORD in your .env)")
        print(f"  4. After creation, open Settings -> Members and invite:")
        print(f"       {b['user_email']}  (role: Editor)")
        print()
    print("=" * 65)


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    print("NocoDB Setup Script")
    print("-" * 40)
    _check_env()

    wait_for_nocodb()
    token = sign_in(ADMIN_EMAIL, ADMIN_PASSWORD)

    # Create test users
    print("\nCreating test users …")
    user_map: dict[str, str | None] = {}
    for b in BASES:
        email = b["user_email"]
        uid = create_user(token, email, TEST_PASSWORD)
        if uid is None:
            uid = get_user_id_by_email(token, email)
        user_map[email] = uid

    # Create bases and invite users
    print("\nCreating bases …")
    failed_bases = []
    for b in BASES:
        base_id = create_external_base(token, b["title"], b["schema"])
        if base_id:
            invite_user_to_base(token, base_id, b["user_email"])
        else:
            failed_bases.append(b)

    # Summary
    print()
    existing = list_bases(token)
    created_titles = {bx["title"] for bx in existing}
    print("Bases visible in NocoDB:")
    for bx in existing:
        print(f"  [{bx['id']}] {bx['title']}")

    print()
    print("Test user credentials:")
    print(f"  finance@test.local  /  {TEST_PASSWORD}")
    print(f"  sales@test.local    /  {TEST_PASSWORD}")
    print(f"  ops@test.local      /  {TEST_PASSWORD}")

    print_manual_steps(failed_bases)

    if not failed_bases:
        print("\nSetup complete!")
    else:
        print(f"\nSetup partially complete — {len(failed_bases)} base(s) need manual creation (see above).")


if __name__ == "__main__":
    main()
