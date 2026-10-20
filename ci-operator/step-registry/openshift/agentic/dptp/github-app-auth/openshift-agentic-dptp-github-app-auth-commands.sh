#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== DPTP GitHub App Auth ==="

CRED_DIR="/var/run/github-token"
APP_ID_FILE="${CRED_DIR}/app-id"
PRIVATE_KEY="${CRED_DIR}/private-key"

[[ -f "${APP_ID_FILE}" ]] || { echo "ERROR: ${APP_ID_FILE} not found."; exit 1; }
[[ -f "${PRIVATE_KEY}" ]] || { echo "ERROR: ${PRIVATE_KEY} not found."; exit 1; }

# Persist the output mapping so later steps can refresh without this env var.
echo "${GITHUB_APP_TOKEN_OUTPUTS}" > "${SHARED_DIR}/github-app-token-outputs"

# Step-registry refs only ship their own commands.sh, so the reusable token
# helpers have to live on SHARED_DIR for later steps to source.
cat > "${SHARED_DIR}/github-app-auth.sh" << 'HEREDOC_EOF'
#!/bin/bash
# DPTP GitHub App token helpers. Source from later steps:
#   source "${SHARED_DIR}/github-app-auth.sh"
#
# GitHub App installation tokens always expire after 1 hour; GitHub does not
# allow a longer TTL. Long-running steps must refresh.

GITHUB_APP_CRED_DIR="${GITHUB_APP_CRED_DIR:-/var/run/github-token}"

generate_jwt() {
    local exp_seconds=${1:-600}
    local now hdr pay sig app_id
    app_id=$(tr -d '[:space:]' < "${GITHUB_APP_CRED_DIR}/app-id")
    now=$(date +%s)
    hdr=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    pay=$(echo -n "{\"iat\":$((now - 60)),\"exp\":$((now + exp_seconds)),\"iss\":\"${app_id}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    sig=$(echo -n "${hdr}.${pay}" | openssl dgst -sha256 -sign "${GITHUB_APP_CRED_DIR}/private-key" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    echo "${hdr}.${pay}.${sig}"
}

generate_token() {
    local installation_id=$1
    local jwt token
    jwt=$(generate_jwt 600)

    token=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
        -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

    [[ -n "${token}" ]] || return 1
    echo "${token}"
}

# Mint a fresh installation token for every mapping in github-app-token-outputs.
# Tokens are staged in a temp dir and only replace SHARED_DIR files after every
# mapping succeeds, so a mid-loop failure leaves existing files and exports as-is.
refresh_github_tokens() {
    local outputs_file="${SHARED_DIR}/github-app-token-outputs"
    local pairs pair id_file output_name id_path installation_id token tmpdir
    local was_tracing=false
    local -a staged=()

    [[ -f "${outputs_file}" ]] || {
        echo "ERROR: ${outputs_file} not found — github-app-auth step must run first" >&2
        return 1
    }

    tmpdir=$(mktemp -d) || return 1

    echo "Refreshing GitHub App installation tokens..."
    IFS=',' read -ra pairs <<< "$(cat "${outputs_file}")"
    for pair in "${pairs[@]}"; do
        id_file="${pair%%:*}"
        output_name="${pair##*:}"

        if [[ ! "${id_file}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "ERROR: Invalid id_file name '${id_file}'." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        if [[ ! "${output_name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "ERROR: Invalid output_name '${output_name}'." >&2
            rm -rf "${tmpdir}"
            return 1
        fi

        id_path="${GITHUB_APP_CRED_DIR}/${id_file}"
        if [[ ! -f "${id_path}" ]]; then
            echo "ERROR: Installation ID file ${id_path} not found." >&2
            rm -rf "${tmpdir}"
            return 1
        fi

        installation_id=$(cat "${id_path}")
        if [[ ! "${installation_id}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Installation ID from ${id_file} is not numeric." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        echo "  Generating token for ${id_file}..."

        [[ $- == *x* ]] && was_tracing=true || was_tracing=false
        set +x
        token=$(generate_token "${installation_id}") || token=""
        if [[ -z "${token}" ]]; then
            ${was_tracing} && set -x
            echo "ERROR: Failed to generate token for ${id_file}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        if ! echo "${token}" > "${tmpdir}/${output_name}"; then
            ${was_tracing} && set -x
            echo "ERROR: Failed to stage token for ${id_file}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        staged+=("${output_name}")
        ${was_tracing} && set -x
    done

    for output_name in "${staged[@]}"; do
        if ! mv -f "${tmpdir}/${output_name}" "${SHARED_DIR}/${output_name}"; then
            echo "ERROR: Failed to install ${output_name}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        echo "  Written to \${SHARED_DIR}/${output_name}"
    done
    rm -rf "${tmpdir}"

    [[ $- == *x* ]] && was_tracing=true || was_tracing=false
    set +x
    GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
    export GH_FORK_TOKEN
    GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
    export GITHUB_TOKEN
    ${was_tracing} && set -x

    echo "GitHub App tokens refreshed"
}

# Read already-minted tokens from SHARED_DIR into the environment.
load_github_tokens() {
    local was_tracing=false
    [[ $- == *x* ]] && was_tracing=true || was_tracing=false
    set +x
    GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
    export GH_FORK_TOKEN
    GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
    export GITHUB_TOKEN
    if [[ "${was_tracing}" == "true" ]]; then
        set -x
    fi
}

# Point git at the token file so pushes pick up refreshes without re-exporting.
configure_github_git_credentials() {
    [[ "${EVAL_MODE:-}" == "true" ]] && return 0
    git config --global credential.helper "!f() { echo username=x-access-token; echo \"password=\$(cat ${SHARED_DIR}/gh-fork-token)\"; }; f"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/github-app-auth.sh"

# Step-registry refs only receive their own commands.sh. Publish local commits
# through the GitHub App so GitHub signs them instead of pushing unsigned Git
# objects. Keep the helper on SHARED_DIR for both solve and review steps.
cat > "${SHARED_DIR}/publish-signed-commits.py" <<'PYTHON_EOF'
#!/usr/bin/env python3
"""Replay local commits through the GitHub App's Git Database API."""

import base64
import json
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


def git(*args):
    return subprocess.check_output(("git", *args))


def api(token, repo, method, path, payload=None):
    url = "https://api.github.com/repos/{}/{}".format(repo, path)
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("message", "request failed")
        except (ValueError, UnicodeDecodeError):
            message = "request failed"
        raise RuntimeError("GitHub API {} {} returned {}: {}".format(
            method, path, error.code, message)) from error


def text(*args):
    return git(*args).decode("utf-8").strip()


def changed_entries(parent, commit):
    raw = git("diff-tree", "--raw", "-r", "--no-renames", "-z", parent, commit)
    fields = raw.split(b"\0")
    if fields[-1] != b"":
        raise RuntimeError("unexpected git diff-tree output")
    entries = []
    for index in range(0, len(fields) - 1, 2):
        header = fields[index].decode("ascii").split()
        if len(header) != 5 or not header[0].startswith(":"):
            raise RuntimeError("unexpected git diff-tree entry")
        old_mode = header[0][1:]
        mode = header[1]
        object_id = header[3]
        status = header[4]
        path = fields[index + 1].decode("utf-8", "surrogateescape")
        if status not in ("A", "D", "M", "T"):
            raise RuntimeError("unsupported git change status " + status)
        if status == "D":
            entries.append({
                "path": path,
                "mode": old_mode,
                "type": "commit" if old_mode == "160000" else "blob",
                "sha": None,
            })
        else:
            if mode not in ("100644", "100755", "120000", "160000"):
                raise RuntimeError("unsupported git mode " + mode)
            entries.append({"path": path, "mode": mode, "sha": object_id})
    return entries


def publish_commit(token, repo, parent, source_parent, source_commit):
    entries = changed_entries(source_parent, source_commit)
    if not entries:
        raise RuntimeError("refusing to publish an empty commit")
    tree_entries = []
    for entry in entries:
        if entry["sha"] is None:
            tree_entries.append(entry)
            continue
        if entry["mode"] == "160000":
            tree_entries.append({**entry, "type": "commit"})
            continue
        contents = git("cat-file", "blob", entry["sha"])
        blob = api(token, repo, "POST", "git/blobs", {
            "content": base64.b64encode(contents).decode("ascii"),
            "encoding": "base64",
        })
        if blob["sha"] != entry["sha"]:
            raise RuntimeError("GitHub blob differs from local object " + entry["sha"])
        tree_entries.append({**entry, "type": "blob", "sha": blob["sha"]})

    parent_commit = api(token, repo, "GET", "git/commits/" + parent)
    tree = api(token, repo, "POST", "git/trees", {
        "base_tree": parent_commit["tree"]["sha"],
        "tree": tree_entries,
    })
    expected_tree = text("rev-parse", source_commit + "^{tree}")
    if tree["sha"] != expected_tree:
        raise RuntimeError("GitHub tree differs from local commit " + source_commit)

    message = git("show", "-s", "--format=%B", source_commit).decode("utf-8")
    created = api(token, repo, "POST", "git/commits", {
        "message": message,
        "tree": tree["sha"],
        "parents": [parent],
    })
    verification = created.get("verification") or {}
    if verification.get("verified") is not True:
        raise RuntimeError("GitHub did not verify commit {}: {}".format(
            created.get("sha", "<unknown>"), verification.get("reason", "unknown")))
    return created["sha"]


def main():
    if len(sys.argv) != 5:
        raise RuntimeError("usage: publish-signed-commits.py REPO BRANCH BASE TOKEN_FILE")
    repo, branch, base, token_file = sys.argv[1:]
    if len(repo.split("/")) != 2 or not all(repo.split("/")):
        raise RuntimeError("invalid fork repository")
    if text("check-ref-format", "--branch", branch) != branch:
        raise RuntimeError("invalid branch name")
    head = text("rev-parse", "HEAD")
    if text("symbolic-ref", "--short", "HEAD") != branch:
        raise RuntimeError("local branch differs from target branch")
    commits = text("rev-list", "--reverse", base + ".." + head).splitlines()

    source_parent = base
    for source_commit in commits:
        parents = text("rev-list", "--parents", "-n", "1", source_commit).split()
        if parents != [source_commit, source_parent]:
            raise RuntimeError("local commits must be linear descendants of " + base)
        source_parent = source_commit

    with open(token_file, encoding="ascii") as token_input:
        token = token_input.read().strip()
    if not token:
        raise RuntimeError("fork installation token is empty")
    ref_path = "git/ref/heads/" + urllib.parse.quote(branch, safe="/")
    current = api(token, repo, "GET", ref_path)["object"]["sha"]
    if current != base:
        raise RuntimeError("fork branch changed: expected {}, found {}".format(base, current))
    if not commits:
        print(base)
        return

    signed_parent = base
    source_parent = base
    for source_commit in commits:
        signed_parent = publish_commit(token, repo, signed_parent, source_parent, source_commit)
        source_parent = source_commit
        print("Created verified GitHub App commit " + signed_parent, file=sys.stderr)

    current = api(token, repo, "GET", ref_path)["object"]["sha"]
    if current != base:
        raise RuntimeError("fork branch changed during commit creation")
    updated = api(token, repo, "PATCH", "git/refs/heads/" + urllib.parse.quote(branch, safe="/"), {
        "sha": signed_parent,
        "force": False,
    })
    if updated["object"]["sha"] != signed_parent:
        raise RuntimeError("fork branch did not move to verified commit")
    print(signed_parent)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError, KeyError, OSError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        sys.exit(1)
PYTHON_EOF
chmod +x "${SHARED_DIR}/publish-signed-commits.py"

# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"

# Resolve app slug (used by review-responder for bot identity)
app_json=""
for attempt in 1 2 3 4; do
    app_json=$(curl -sf --connect-timeout 10 --max-time 15 \
        -H "Authorization: Bearer $(generate_jwt 120)" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app") && break
    echo "GET https://api.github.com/app failed (attempt ${attempt}/4), retrying..."
    sleep $((attempt * 5))
done
[[ -n "${app_json}" ]] || {
    echo "ERROR: GET https://api.github.com/app failed after 4 attempts."
    exit 1
}
APP_SLUG=$(echo "${app_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug',''))")
[[ -n "${APP_SLUG}" ]] || { echo "ERROR: Failed to resolve app slug from /app endpoint."; exit 1; }
echo "${APP_SLUG}[bot]" > "${SHARED_DIR}/gh-app-bot-login"
echo "App slug: ${APP_SLUG} (bot login: ${APP_SLUG}[bot])"

refresh_github_tokens || { echo "ERROR: Failed to generate GitHub App tokens."; exit 1; }

echo "=== DPTP GitHub App Auth Complete ==="
