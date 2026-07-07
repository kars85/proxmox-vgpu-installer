# shellcheck shell=bash
# lib/repos.sh — APT repository configuration for PVE 8 (.list) and PVE 9 (deb822 .sources).
# Adds the no-subscription repo and disables the enterprise repo without blind-sed'ing
# user files.

# PVE 9 (Debian 13 trixie) uses deb822 *.sources files.
_setup_repos_pve9() {
    local codename="${DEBIAN_CODENAME:-trixie}"
    log_info "Configuring deb822 repositories for Proxmox 9 (${codename})"

    # Modernize any leftover legacy .list entries first (idempotent).
    if apt --help 2>/dev/null | grep -q modernize-sources; then
        run_command "Modernizing legacy APT sources" info apt modernize-sources -y || true
    fi

    # Disable enterprise repos (both pve and ceph) if present.
    local ent
    for ent in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
        if [ -f "$ent" ] && ! grep -q '^Enabled: false' "$ent"; then
            log_info "Disabling enterprise repo: $(basename "$ent")"
            printf '\nEnabled: false\n' >>"$ent"
        fi
    done
    # Legacy .list enterprise entries that survived (comment them out).
    _comment_enterprise_list_entries

    # Write the no-subscription repo in deb822 format.
    local target=/etc/apt/sources.list.d/pve-no-subscription.sources
    cat >"$target" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${codename}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    log_info "Wrote $target"
}

# PVE 8 (Debian 12 bookworm) keeps legacy .list repos.
_setup_repos_pve8() {
    log_info "Configuring repositories for Proxmox 8 (bookworm)"
    local repo="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
    _replace_repo_line "deb https://enterprise.proxmox.com/debian/pve bookworm pve-enterprise" "$repo"
    _comment_enterprise_list_entries
    if ! grep -rqs "download.proxmox.com/debian/pve bookworm pve-no-subscription" /etc/apt/; then
        log_info "Adding no-subscription repo to /etc/apt/sources.list"
        echo "$repo" >>/etc/apt/sources.list
    fi
}

_setup_repos_pve7() {
    log_info "Configuring repositories for Proxmox 7 (bullseye)"
    local repo="deb http://download.proxmox.com/debian/pve bullseye pve-no-subscription"
    _replace_repo_line "deb https://enterprise.proxmox.com/debian/pve bullseye pve-enterprise" "$repo"
    _comment_enterprise_list_entries
    if ! grep -rqs "download.proxmox.com/debian/pve bullseye pve-no-subscription" /etc/apt/; then
        echo "$repo" >>/etc/apt/sources.list
    fi
}

# Replace an exact legacy repo line wherever it appears under /etc/apt.
_replace_repo_line() {
    local old="$1" new="$2" f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] || continue
        if grep -qF "$old" "$f"; then
            sed -i "s|$(printf '%s' "$old" | sed 's/[|]/\\|/g')|$new|" "$f"
            log_info "Updated repo line in $f"
        fi
    done
}

# Comment out enterprise .list entries (both pve and ceph) so apt update stops 401'ing.
_comment_enterprise_list_entries() {
    local f
    for f in /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list; do
        [ -f "$f" ] || continue
        if grep -qE '^\s*deb .*enterprise\.proxmox\.com' "$f"; then
            sed -i 's|^\(\s*deb .*enterprise\.proxmox\.com.*\)$|# \1|' "$f"
            log_info "Commented enterprise entries in $(basename "$f")"
        fi
    done
}

setup_repositories() {
    case "${PVE_MAJOR}" in
        9) _setup_repos_pve9 ;;
        8) _setup_repos_pve8 ;;
        7) _setup_repos_pve7 ;;
        *) log_warn "Skipping repo setup for unknown PVE major ${PVE_MAJOR}" ;;
    esac
    run_command "Running apt update" info apt-get update
}

module_init "repos.sh"
