#!/usr/bin/env bash
# ==============================================================================
#  openGym LXC installer / updater for Proxmox VE
#  App:    https://github.com/DuarteSantos8/openGym  (AGPL-3.0)
#  Source: builds from your fork (REPO below) — upstream releases optional.
#  Style:  modelled on community-scripts / helper-scripts.com, but fully
#          self-contained (no dependency on their build.func, which can only
#          run install scripts hosted in their own repo).
#
#  ON THE PROXMOX HOST (as root):
#     bash opengym-lxc.sh                    # interactive create + install
#     bash opengym-lxc.sh --ctid 120 --hostname opengym --ip dhcp --yes
#     bash opengym-lxc.sh update 120         # update the app inside CT 120
#     bash opengym-lxc.sh update 120 --ref my-branch                # deploy a branch of the fork
#     bash opengym-lxc.sh update 120 --repo DuarteSantos8/openGym   # switch to upstream releases
#     bash opengym-lxc.sh auto-update 120 on                        # nightly update of CT 120
#     bash opengym-lxc.sh auto-update 120 on --notify-url https://ntfy.sh/<your-topic>
#
#  INSIDE THE CONTAINER (or any Debian 12/13 box):
#     update                                 # newest commit on main (fork) / newest release (upstream)
#     update --ref v1.4.1                    # a specific tag, branch or commit
#     update --force                         # rebuild the current version
#     opengym-lxc.sh --auto-update on|off|status    # nightly 'update' via a systemd timer
#     bash opengym-lxc.sh --install-only     # install onto an existing box
#
#  AUTO-UPDATE runs 'update' at night: it only rebuilds when the source moved,
#  backs up the data first and rolls back if the new version won't start.
#  It deploys whatever the CT tracks: your fork's main (you decide what gets
#  merged), or every new upstream release if the CT tracks upstream. Settings
#  (schedule, alert URL) live in /etc/opengym/auto-update.env.
#
#  Run it from a saved file (bash opengym-lxc.sh), not "bash -c $(curl …)",
#  because the host copies this same file into the container.
# ==============================================================================
set -Eeuo pipefail
# Debian CT templates ship only C.UTF-8; the host's LANG=en_US.UTF-8 leaks in
# through pct exec and makes every perl/apt call warn. C.UTF-8 always exists.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
# 'pct exec' starts with a minimal PATH that lacks /usr/local/bin, where uv and
# this script's own helpers live. Set the standard Debian root PATH explicitly.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# ------------------------------------------------------------------ constants
APP="openGym"
NSAPP="opengym"
DEFAULT_REPO="aaronjevitt/openGym"       # where builds come from (your fork)
UPSTREAM_REPO="DuarteSantos8/openGym"    # upstream: deploys its newest release
MEDIA_REPO="https://github.com/hasaneyldrm/exercises-dataset"
NODE_MAJOR="22"

APP_DIR="/opt/${NSAPP}"                 # source checkout (replaced on update)
DATA_DIR="/opt/${NSAPP}-data"           # users, passkeys, workouts  -> BACK UP
MEDIA_DIR="/opt/${NSAPP}-media"         # exercise img/gif (downloaded once)
COACH_AUTH_DIR="/opt/${NSAPP}-coach-auth"
WWW_DIR="/var/www/${NSAPP}"             # built frontend served by nginx
CONF_DIR="/etc/${NSAPP}"
ENV_FILE="${CONF_DIR}/${NSAPP}.env"     # runtime config (kept on update)
SOURCE_ENV="${CONF_DIR}/source.env"     # which repo this CT builds from (kept on update)
AUTO_ENV="${CONF_DIR}/auto-update.env"  # auto-update schedule + alert URL (kept on update)
AUTO_UNIT="${NSAPP}-auto-update"        # systemd service + timer name
UPDATE_LOCK="/run/${NSAPP}-update.lock" # one update at a time, manual or timed
VERSION_FILE="/opt/${NSAPP}_version.txt"
BACKUP_DIR="/opt/${NSAPP}-backups"
SERVICE="${NSAPP}-api"
API_PORT="3000"
SELF_INSTALL_PATH="/usr/local/bin/${NSAPP}-lxc.sh"

# ------------------------------------------------------------------- defaults
CTID=""
HN="${NSAPP}"
CORES="2"
RAM="2048"          # MB — the Vite build wants ~1.5 GB headroom
SWAP="512"
DISK="8"            # GB
STORAGE=""          # rootfs storage, auto-detected
TMPL_STORAGE=""     # template storage, auto-detected
BRIDGE="vmbr0"
NET_IP="dhcp"       # or e.g. 192.168.1.50/24
NET_GW=""
VLAN=""
UNPRIV="1"
PASSWORD=""
ONBOOT="1"
RP_ID=""            # passkey hostname; empty -> container hostname/IP
ORIGIN=""           # full URL; empty -> http://<ip>
RP_NAME="${APP}"
ASSUME_YES="0"
FORCE="0"
REF=""              # tag, branch or SHA; empty -> main (fork) / latest release (upstream)
REPO_ARG=""
WITH_COACH="0"      # bundle the Claude Agent SDK so the AI Coach can use a Claude subscription
AUTO_ACTION=""
NOTIFY_URL_IN=""
MODE=""

# ------------------------------------------------------------------- helpers
YW=$'\033[33m'; GN=$'\033[1;92m'; RD=$'\033[01;31m'; BL=$'\033[36m'; CL=$'\033[m'; BOLD=$'\033[1m'
msg_info() { echo -e " ${YW}⏳${CL} $*"; }
msg_ok()   { echo -e " ${GN}✔${CL} $*"; }
msg_warn() { echo -e " ${YW}⚠${CL} $*"; }
msg_error(){ echo -e " ${RD}✖${CL} $*" >&2; }
die()      { msg_error "$*"; exit 1; }
trap 'msg_error "Failed at line $LINENO: $BASH_COMMAND"' ERR

header() {
  cat <<'EOF'
                       ____
  ____  ____  ___  ____/ __ \__  ______ ___
 / __ \/ __ \/ _ \/ __ \ / / / / / / __ `__ \
/ /_/ / /_/ /  __/ / / / /_/ / /_/ / / / / / /
\____/ .___/\___/_/ /_/\____/\__, /_/ /_/ /_/
    /_/                     /____/   LXC installer
EOF
}

usage() {
  awk 'NR>2 && /^# =+$/ {exit} NR>2' "$0" | sed -E 's/^# ?//'
  cat <<EOF

Create options (host):
  --ctid N            container id (default: next free)
  --hostname NAME     (default: ${HN})
  --cores N           (default: ${CORES})
  --memory MB         (default: ${RAM})
  --swap MB           (default: ${SWAP})
  --disk GB           (default: ${DISK})
  --storage NAME      rootfs storage (default: first that supports containers)
  --bridge NAME       (default: ${BRIDGE})
  --ip dhcp|CIDR      (default: ${NET_IP})     --gw IP    --vlan TAG
  --privileged        create a privileged CT (default: unprivileged)
  --password PW       root password (default: none; use 'pct enter')
  --rp-id HOST        passkey hostname, e.g. gym.example.com
  --origin URL        e.g. https://gym.example.com  (must match RP_ID)
  --repo OWNER/NAME   GitHub repo to build from (default: ${DEFAULT_REPO});
                      remembered in ${SOURCE_ENV} for later updates
  --ref TAG|BRANCH|SHA  what to build (default: 'main' for a fork, the newest
                      release for ${UPSTREAM_REPO})
  --with-coach        include the Claude Agent SDK (~300 MB) so the AI Coach can
                      run on a Claude subscription via 'claude setup-token'
  --auto-update on    also install the nightly auto-update timer
  --notify-url URL    where auto-update posts failures (ntfy topic URL or any
                      endpoint that takes a plain-text POST)
  --yes               don't ask for confirmation

Auto-update (host: 'auto-update <CTID> ACTION', inside the CT: '--auto-update ACTION'):
  on      install/enable the timer (default: nightly 04:00 + up to 30 min jitter)
  off     disable it (settings in ${AUTO_ENV} are kept)
  status  show the timer and the last run
EOF
}

# ------------------------------------------------------------- arg parsing
while [[ $# -gt 0 ]]; do
  case "$1" in
    update)          MODE="host-update"; CTID="${2:-}"; [[ $# -gt 1 ]] && shift ;;
    auto-update)     MODE="host-auto"; CTID="${2:-}"; AUTO_ACTION="status"
                     [[ $# -gt 1 ]] && shift
                     if [[ $# -gt 1 && "${2:-}" != -* ]]; then AUTO_ACTION="$2"; shift; fi ;;
    --auto-update)   AUTO_ACTION="$2"; shift ;;
    --notify-url)    NOTIFY_URL_IN="$2"; shift ;;
    --install-only)  MODE="ct-install" ;;
    --update-only)   MODE="ct-update" ;;
    --ctid)          CTID="$2"; shift ;;
    --hostname)      HN="$2"; shift ;;
    --cores)         CORES="$2"; shift ;;
    --memory)        RAM="$2"; shift ;;
    --swap)          SWAP="$2"; shift ;;
    --disk)          DISK="$2"; shift ;;
    --storage)       STORAGE="$2"; shift ;;
    --bridge)        BRIDGE="$2"; shift ;;
    --ip)            NET_IP="$2"; shift ;;
    --gw)            NET_GW="$2"; shift ;;
    --vlan)          VLAN="$2"; shift ;;
    --privileged)    UNPRIV="0" ;;
    --password)      PASSWORD="$2"; shift ;;
    --rp-id)         RP_ID="$2"; shift ;;
    --origin)        ORIGIN="$2"; shift ;;
    --rp-name)       RP_NAME="$2"; shift ;;
    --repo)          REPO_ARG="$2"; shift ;;
    --ref)           REF="$2"; shift ;;
    --force)         FORCE="1" ;;
    --with-coach)    WITH_COACH="1" ;;
    --yes|-y)        ASSUME_YES="1" ;;
    -h|--help)       usage; exit 0 ;;
    *) die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done

# --repo wins; else what this CT was installed from; else the default.
REPO="$DEFAULT_REPO"
if [[ -n "$REPO_ARG" ]]; then REPO="$REPO_ARG"
elif [[ -f "$SOURCE_ENV" ]]; then REPO="$(sed -n 's/^REPO=//p' "$SOURCE_ENV")"; REPO="${REPO:-$DEFAULT_REPO}"
fi
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid --repo '${REPO}' (expected OWNER/NAME)"
[[ -z "$AUTO_ACTION" || "$AUTO_ACTION" =~ ^(on|off|status|run)$ ]] \
  || die "Invalid auto-update action '${AUTO_ACTION}' (on, off or status)"

# ==============================================================================
#                         CONTAINER-SIDE FUNCTIONS
# ==============================================================================

latest_tag() {
  # Newest vX.Y.Z tag on the repo; GitHub API first, git ls-remote as fallback.
  local t
  t="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -z "$t" ]]; then
    t="$(git ls-remote --tags --refs "https://github.com/${REPO}.git" 2>/dev/null \
        | sed 's#.*/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 || true)"
  fi
  [[ -n "$t" ]] || die "Could not determine the latest ${APP} release of ${REPO}"
  echo "$t"
}

default_ref() {
  # A fork has no releases of its own: track its main branch.
  if [[ "$REPO" == "$UPSTREAM_REPO" ]]; then latest_tag; else echo "main"; fi
}

resolve_ref() {
  # Pin a branch to its current commit ("main@1a2b3c4d5e6f") so 'update' only
  # rebuilds when the branch actually moved. Tags and SHAs pass through.
  local ref="$1" sha
  sha="$(git ls-remote "https://github.com/${REPO}.git" "refs/heads/${ref}" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$sha" ]]; then echo "${ref}@${sha:0:12}"; else echo "$ref"; fi
}

save_source() {
  mkdir -p "$CONF_DIR"
  echo "REPO=${REPO}" > "$SOURCE_ENV"
}

fetch_source() {
  # $1 is a resolve_ref label: "branch@sha", a tag, or a commit SHA.
  # Leaves a fresh tree in $APP_DIR.new
  local label="$1" ref archive tmp
  ref="${label%%@*}"
  archive="${label#*@}"                    # the SHA for a branch, else the ref itself
  tmp="$(mktemp -d)"; mkdir -p "$tmp/src"
  msg_info "Downloading ${APP} ${label} from ${REPO}"
  # /archive/<ref>.tar.gz resolves branches, tags and commit SHAs alike.
  if curl -fsSL "https://github.com/${REPO}/archive/${archive}.tar.gz" -o "$tmp/src.tgz"; then
    tar -xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1
  else
    msg_warn "Tarball download failed — falling back to git clone"
    rm -rf "$tmp/src"
    git clone --quiet --depth 1 --branch "$ref" "https://github.com/${REPO}.git" "$tmp/src"
    rm -rf "$tmp/src/.git"
  fi
  rm -rf "${APP_DIR}.new"
  mv "$tmp/src" "${APP_DIR}.new"
  rm -rf "$tmp"
  msg_ok "Downloaded ${APP} ${label}"
}

install_base() {
  export DEBIAN_FRONTEND=noninteractive
  msg_info "Installing base packages"
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates gnupg git nginx rsync gettext-base sudo mc >/dev/null
  msg_ok "Installed base packages"

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" != "$NODE_MAJOR" ]]; then
    msg_info "Installing Node.js ${NODE_MAJOR}"
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list
    apt-get update -qq
    apt-get install -y -qq nodejs >/dev/null
    msg_ok "Installed Node.js $(node -v)"
  fi

  # The AI Coach (optional, off by default) drops provider jobs to an
  # unprivileged 'coach' user and refuses to run without one — same as the
  # upstream Docker image.
  id coach >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin coach
}

has_catalogue_media() {
  # v1.4.0+ ships its own (licensed) exercise media in catalogue/media/.
  [[ -d "${1}/catalogue/media/still" ]]
}

fetch_media() {
  # Only releases before v1.4.0 need the external dataset.
  if has_catalogue_media "${APP_DIR}.new"; then
    msg_ok "Exercise media ships with this release (catalogue/media)"
    return
  fi
  if [[ -d "$MEDIA_DIR/images" && -n "$(ls -A "$MEDIA_DIR/images" 2>/dev/null)" ]]; then
    msg_ok "Exercise media already present"
    return
  fi
  msg_info "Downloading exercise media (~140 MB, one time) from ${MEDIA_REPO}"
  echo "   Metadata/instructions: MIT. Images & GIFs: third-party (see NOTICE.md in the repo)."
  rm -rf "$MEDIA_DIR"
  git clone --quiet --depth 1 "$MEDIA_REPO" "$MEDIA_DIR"
  rm -rf "$MEDIA_DIR/.git"
  msg_ok "Exercise media ready ($(ls "$MEDIA_DIR/images" | wc -l) images)"
}

build_frontend() {
  msg_info "Building frontend (this takes a few minutes)"
  ( cd "${APP_DIR}.new/frontend" \
    && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error \
    && NODE_OPTIONS="--max-old-space-size=1536" npm run build --silent )
  msg_ok "Built frontend"

  # The Claude Agent SDK is an optionalDependency upstream; it is what lets the
  # AI Coach run on a Claude subscription (setup-token) instead of an API key.
  local omit=(--omit=dev)
  if coach_sdk_wanted; then
    msg_info "Installing API dependencies (with Claude Agent SDK)"
  else
    msg_info "Installing API dependencies"
    omit+=(--omit=optional)
  fi
  ( cd "${APP_DIR}.new/api" \
    && npm ci "${omit[@]}" --no-audit --no-fund --loglevel=error )
  if coach_sdk_wanted; then
    # Upstream's lockfile pins an SDK whose bundled Claude Code can lag behind the
    # models a subscription defaults to ("version X or newer is required").
    # --no-save keeps package-lock.json untouched so the next update is clean.
    msg_info "Bumping Claude Agent SDK to latest"
    ( cd "${APP_DIR}.new/api" \
      && npm install --no-save --omit=dev --no-audit --no-fund --loglevel=error \
           @anthropic-ai/claude-agent-sdk@latest )
    msg_ok "Claude Agent SDK $(node -p "require('${APP_DIR}.new/api/node_modules/@anthropic-ai/claude-agent-sdk/package.json').version")"
  fi
  msg_ok "Installed API dependencies"
}

coach_sdk_wanted() {
  # --with-coach on the command line, or COACH_SDK=1 remembered in the env file.
  [[ "$WITH_COACH" == "1" ]] && return 0
  [[ -f "$ENV_FILE" ]] && grep -qE '^COACH_SDK=1' "$ENV_FILE"
}

ensure_env_defaults() {
  # Keys added in later releases of this installer, appended to an existing
  # env file without touching anything the operator set.
  [[ -f "$ENV_FILE" ]] || return 0
  grep -qE '^#?[[:space:]]*TRUST_PROXY=' "$ENV_FILE" || {
    printf '\n# nginx overwrites X-Forwarded-For, so the API may trust it.\nTRUST_PROXY=1\n' >> "$ENV_FILE"
    msg_ok "Added TRUST_PROXY=1 to ${ENV_FILE}"
  }
}

write_env_file() {
  # Only on first install; updates keep the operator's edits.
  [[ -f "$ENV_FILE" ]] && return
  mkdir -p "$(dirname "$ENV_FILE")"
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  local rp="${RP_ID:-${ip:-localhost}}"
  local origin="${ORIGIN:-http://${rp}}"
  cat > "$ENV_FILE" <<EOF
# ${APP} runtime configuration — read by ${SERVICE}.service.
# Reference for every key: https://github.com/${UPSTREAM_REPO}/blob/main/.env.example
# After editing:  systemctl restart ${SERVICE}

# Passkeys are bound to this exact hostname and only work over HTTPS
# (http://localhost is the one exception). For phone access put a reverse
# proxy with TLS in front and set both of these to your real domain:
RP_ID=${rp}
ORIGIN=${origin}
RP_NAME=${RP_NAME}

PORT=${API_PORT}
DATA_DIR=${DATA_DIR}
COACH_CREDENTIAL_DIR=${COACH_AUTH_DIR}
NODE_ENV=production
# nginx in this CT overwrites X-Forwarded-For, so the API may trust it (v1.4+
# throttles failed sign-ins per address).
TRUST_PROXY=1
# Installer marker: 1 = keep the Claude Agent SDK installed on updates
# (AI Coach via 'claude setup-token'). Not read by openGym itself.
COACH_SDK=${WITH_COACH}

# SESSION_DAYS=90
# ADMIN_UIDS=
# INVITE_ONLY=1
# ALLOW_GUEST=0
# AUDIT_LOG=0
# AUDIT_IP=off
# VAPID_SUBJECT=mailto:you@example.com
# COACH_DISABLED=1
EOF
  chmod 600 "$ENV_FILE"
  msg_ok "Wrote ${ENV_FILE}"
}

write_service() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=${APP} API (passkeys + per-user data)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}/api
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node server.js
Restart=on-failure
RestartSec=5
# Runs as root on purpose: the (optional) AI Coach drops each provider job to
# the 'coach' user and refuses to run if it can't — matching upstream's image.
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${COACH_AUTH_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable -q "${SERVICE}"
}

write_nginx() {
  # Render upstream's own nginx template so proxy/caching rules stay in sync
  # with the release; only the substitutions Docker would make are applied.
  # Every ${VAR} in the template is substituted; values come from, in rising
  # priority: upstream's web/Dockerfile ENV defaults, the env file (so e.g.
  # MEDIA_UPLOAD_MAX or CF_CONNECTING_IP can be set there), then the values
  # this native layout requires. Unknown future variables therefore get
  # upstream's own default instead of breaking 'nginx -t'.
  local tpl="${APP_DIR}/web/nginx.conf.template"
  local dockerfile="${APP_DIR}/web/Dockerfile"
  [[ -f "$tpl" ]] || die "nginx template missing at $tpl"
  local -A val=()
  local line k v
  if [[ -f "$dockerfile" ]]; then
    while IFS= read -r line; do
      k="${line%%=*}"; v="${line#*=}"; v="${v#\"}"; v="${v%\"}"
      val[$k]="$v"
    done < <(sed -nE 's/^ENV[[:space:]]+([A-Z_][A-Z0-9_]*)=(.*)$/\1=\2/p' "$dockerfile")
  fi
  local vars; vars="$(grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' "$tpl" | sort -u | tr -d '${}')"
  for k in $vars; do
    line="$(grep -E "^${k}=" "$ENV_FILE" 2>/dev/null | tail -1 || true)"
    [[ -n "$line" ]] && val[$k]="${line#*=}"
  done
  val[NGINX_PORT]=80; val[BACKEND]=127.0.0.1; val[PORT]="$API_PORT"; val[RESOLVER]=127.0.0.1
  val[BASE_PATH]="${val[BASE_PATH]:-}"; val[CF_CONNECTING_IP]="${val[CF_CONNECTING_IP]:-}"
  local subst="" missing=()
  for k in $vars; do
    [[ -v "val[$k]" ]] || missing+=("$k")
    export "$k=${val[$k]:-}"
    subst+="\${$k} "
  done
  (( ${#missing[@]} == 0 )) || die "nginx template uses ${missing[*]} with no known default — set it in ${ENV_FILE}"
  envsubst "$subst" < "$tpl" \
    | sed -e "s#root /usr/share/nginx/html;#root ${WWW_DIR};#" \
          -e "s#listen 80;#listen 80;\n    listen [::]:80;#" \
    > /etc/nginx/sites-available/${NSAPP}
  if grep -qE '\$\{[A-Z_]+\}' /etc/nginx/sites-available/${NSAPP}; then
    die "unsubstituted variable left in nginx config: $(grep -oE '\$\{[A-Z_]+\}' /etc/nginx/sites-available/${NSAPP} | sort -u | tr '\n' ' ')"
  fi
  ln -sf /etc/nginx/sites-available/${NSAPP} /etc/nginx/sites-enabled/${NSAPP}
  rm -f /etc/nginx/sites-enabled/default
  nginx -t -q
  systemctl enable -q nginx
  systemctl reload nginx || systemctl restart nginx
}

deploy_frontend() {
  mkdir -p "$WWW_DIR"
  rsync -a --delete --exclude img --exclude gif --exclude exercise-media \
    "${APP_DIR}/frontend/dist/" "$WWW_DIR/"
  if has_catalogue_media "$APP_DIR"; then
    # v1.4+: media ships in the release tree; link it rather than copy 190 MB.
    rm -rf "$WWW_DIR/exercise-media"
    ln -sfn "$APP_DIR/catalogue/media" "$WWW_DIR/exercise-media"
    rm -f "$WWW_DIR/img" "$WWW_DIR/gif"
    chmod -R o+rX "$APP_DIR/catalogue/media"
  else
    # pre-1.4 layout (also used when rolling back to one)
    rm -f "$WWW_DIR/exercise-media"
    ln -sfn "$MEDIA_DIR/images" "$WWW_DIR/img"
    ln -sfn "$MEDIA_DIR/videos" "$WWW_DIR/gif"
    chmod -R o+rX "$MEDIA_DIR"
  fi
  chown -R www-data:www-data "$WWW_DIR"
}

wait_healthy() {
  # Up to ~60 s for the API to answer through nginx.
  local i
  for i in $(seq 1 30); do
    curl -fsS -m 3 "http://127.0.0.1/api/health" >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

install_update_cmd() {
  # Keep a copy of this script in the CT and expose `update` like the
  # community scripts do.
  if [[ -f "$0" && "$(readlink -f "$0")" != "$SELF_INSTALL_PATH" ]]; then
    install -m 755 "$0" "$SELF_INSTALL_PATH"
  fi
  cat > /usr/local/bin/update <<EOF
#!/usr/bin/env bash
exec bash "${SELF_INSTALL_PATH}" --update-only "\$@"
EOF
  chmod 755 /usr/local/bin/update
}

motd() {
  cat > /etc/motd <<EOF

  ${APP} — self-hosted gym & body-weight tracker
  ---------------------------------------------
  Web UI    : http://$(hostname -I 2>/dev/null | awk '{print $1}')/
  Config    : ${ENV_FILE}     (RP_ID / ORIGIN for passkeys)
  Data      : ${DATA_DIR}     <- back this up
  Backups   : ${BACKUP_DIR}   (taken before every update)
  Logs      : journalctl -u ${SERVICE} -f
  Update    : update            (or: update --force / update --ref <tag|branch>)
  Auto      : $(systemctl is-enabled -q "${AUTO_UNIT}.timer" 2>/dev/null && echo "nightly (${NSAPP}-lxc.sh --auto-update status)" || echo "off (${NSAPP}-lxc.sh --auto-update on)")
  Source    : ${REPO}
  Version   : $(cat "$VERSION_FILE" 2>/dev/null)

EOF
}

ct_install() {
  [[ $EUID -eq 0 ]] || die "Run as root"
  [[ -f /etc/debian_version ]] || die "This installer expects Debian 12/13"
  msg_info "Installing ${APP} into $(hostname)"
  install_base
  local ref; ref="$(resolve_ref "${REF:-$(default_ref)}")"
  fetch_source "$ref"
  fetch_media
  build_frontend
  rm -rf "$APP_DIR" && mv "${APP_DIR}.new" "$APP_DIR"
  mkdir -p "$DATA_DIR"; chmod 700 "$DATA_DIR"
  mkdir -p "$COACH_AUTH_DIR"; chown coach:coach "$COACH_AUTH_DIR"; chmod 700 "$COACH_AUTH_DIR"
  mkdir -p "$BACKUP_DIR"
  write_env_file
  save_source
  write_service
  deploy_frontend
  write_nginx
  echo "$ref" > "$VERSION_FILE"
  systemctl restart "${SERVICE}"
  install_update_cmd
  [[ "$AUTO_ACTION" == "on" ]] && ct_auto on
  motd
  if wait_healthy; then
    msg_ok "${APP} ${ref} is up: http://$(hostname -I | awk '{print $1}')/"
  else
    msg_warn "API health check failed — see: journalctl -u ${SERVICE} -n 50"
  fi
  msg_info "Cleaning up"
  apt-get -y -qq autoremove >/dev/null; apt-get -y -qq autoclean >/dev/null
  npm cache clean --force >/dev/null 2>&1 || true
  msg_ok "Done"
}

ct_update() {
  [[ $EUID -eq 0 ]] || die "Run as root"
  [[ -d "$APP_DIR" && -f "$VERSION_FILE" ]] || die "${APP} is not installed here (run with --install-only first)"
  # A manual 'update' and the nightly timer must never swap the app at once.
  exec 9>"$UPDATE_LOCK"
  flock -n 9 || die "Another ${APP} update is already running"
  local current target backup rc
  current="$(cat "$VERSION_FILE")"
  target="$(resolve_ref "${REF:-$(default_ref)}")"
  if [[ "$current" == "$target" && "$FORCE" != "1" ]]; then
    msg_ok "${APP} is already at ${current} — nothing to do (use --force to rebuild)"
    return
  fi
  msg_info "Updating ${APP}: ${current} -> ${target} (${REPO})"
  if [[ "$WITH_COACH" == "1" ]] && ! grep -qE '^COACH_SDK=1' "$ENV_FILE"; then
    sed -i '/^COACH_SDK=/d' "$ENV_FILE"; echo "COACH_SDK=1" >> "$ENV_FILE"
  fi
  ensure_env_defaults
  install_base                      # picks up a Node major bump if we ever change it
  fetch_source "$target"
  fetch_media
  build_frontend                    # the running app is untouched until here

  msg_info "Stopping ${SERVICE} and backing up data"
  systemctl stop "${SERVICE}"
  mkdir -p "$BACKUP_DIR"
  # Branch labels hold '@'; keep the file name plain.
  backup="${BACKUP_DIR}/${NSAPP}-data-${current//[^A-Za-z0-9._-]/_}-$(date +%Y%m%d-%H%M%S).tgz"
  tar -czf "$backup" -C "$(dirname "$DATA_DIR")" "$(basename "$DATA_DIR")"
  ls -1t "${BACKUP_DIR}"/*.tgz 2>/dev/null | tail -n +4 | xargs -r rm -f   # keep the last 3
  msg_ok "Backed up ${DATA_DIR} to ${backup}"

  rm -rf "${APP_DIR}.old"
  mv "$APP_DIR" "${APP_DIR}.old"
  mv "${APP_DIR}.new" "$APP_DIR"
  # Run the switch-over in a subshell so a failure anywhere in it rolls back.
  set +e
  ( set -e; deploy_frontend; write_nginx; systemctl start "${SERVICE}" )
  rc=$?
  [[ $rc -eq 0 ]] && { wait_healthy; rc=$?; }
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "$target" > "$VERSION_FILE"
    save_source
    rm -rf "${APP_DIR}.old"
    install_update_cmd
    motd
    msg_ok "Updated ${APP} to ${target}"
  else
    msg_error "Update failed — rolling back to ${current} (code and data)"
    journalctl -u "${SERVICE}" -n 30 --no-pager || true
    systemctl stop "${SERVICE}" || true
    rm -rf "$APP_DIR"; mv "${APP_DIR}.old" "$APP_DIR"
    # Undo anything the new version wrote to the data dir.
    rm -rf "$DATA_DIR"; tar -xzf "$backup" -C "$(dirname "$DATA_DIR")"
    deploy_frontend; write_nginx; systemctl start "${SERVICE}" || true
    wait_healthy && msg_ok "Rolled back to ${current}" || msg_warn "Rollback started but isn't healthy yet"
    exit 1
  fi
}

# ------------------------------------------------------------- auto-update

auto_env_get() { sed -n "s/^$1=//p" "$AUTO_ENV" 2>/dev/null | tail -1; }

notify() {
  # Best effort: a failed alert is logged, never fatal. ntfy reads the Title
  # header; any endpoint that takes a plain-text POST gets the body.
  local url; url="$(auto_env_get NOTIFY_URL)"
  [[ -n "$url" ]] || return 0
  curl -fsS -m 15 -H "Title: $1" -H "Tags: $2" --data-binary "$3" "$url" >/dev/null \
    || msg_warn "Could not send the alert to ${url}"
}

write_auto_env() {
  mkdir -p "$CONF_DIR"
  if [[ ! -f "$AUTO_ENV" ]]; then
    cat > "$AUTO_ENV" <<EOF
# ${APP} auto-update settings. Apply changes with: ${NSAPP}-lxc.sh --auto-update on
#
# When to run (systemd OnCalendar syntax), plus up to 30 min random delay.
SCHEDULE=*-*-* 04:00
# Where to POST failures, e.g. https://ntfy.sh/<your-topic>. Empty: no alerts.
NOTIFY_URL=
# 1 = also alert when a new version was deployed.
NOTIFY_ON_SUCCESS=0
EOF
    chmod 600 "$AUTO_ENV"
  fi
  if [[ -n "$NOTIFY_URL_IN" ]]; then
    # awk, not sed: a webhook URL may hold '&', '#' or '/'.
    local tmp; tmp="$(mktemp)"
    NOTIFY_URL="$NOTIFY_URL_IN" awk '/^NOTIFY_URL=/ { print "NOTIFY_URL=" ENVIRON["NOTIFY_URL"]; next } { print }' \
      "$AUTO_ENV" > "$tmp"
    cat "$tmp" > "$AUTO_ENV"; rm -f "$tmp"
  fi
}

ct_auto() {
  [[ $EUID -eq 0 ]] || die "Run as root"
  case "$1" in
    on)
      [[ -f "$VERSION_FILE" ]] || die "${APP} is not installed here"
      write_auto_env
      local schedule; schedule="$(auto_env_get SCHEDULE)"
      if [[ "$REPO" == "$UPSTREAM_REPO" ]]; then
        msg_warn "This CT builds from ${UPSTREAM_REPO}: auto-update will deploy every new upstream release unreviewed."
      fi
      cat > "/etc/systemd/system/${AUTO_UNIT}.service" <<EOF
[Unit]
Description=${APP} auto-update (rebuilds only when the source moved)
After=network-online.target ${SERVICE}.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/env bash ${SELF_INSTALL_PATH} --auto-update run
# Keep the running app responsive while the new version builds.
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=1h
EOF
      cat > "/etc/systemd/system/${AUTO_UNIT}.timer" <<EOF
[Unit]
Description=Nightly ${APP} auto-update

[Timer]
OnCalendar=${schedule:-*-*-* 04:00}
RandomizedDelaySec=30min
# Not Persistent: a CT that was off at night skips the run rather than
# rebuilding in the middle of someone's day.
Persistent=false

[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable -q --now "${AUTO_UNIT}.timer"
      msg_ok "Auto-update on (${schedule:-*-*-* 04:00}); settings: ${AUTO_ENV}"
      [[ -n "$(auto_env_get NOTIFY_URL)" ]] || msg_warn "No NOTIFY_URL set: a failed or rolled-back update will only show in: journalctl -u ${AUTO_UNIT}"
      if [[ -f "$ENV_FILE" ]]; then motd; fi
      ;;
    off)
      systemctl disable -q --now "${AUTO_UNIT}.timer" 2>/dev/null || true
      msg_ok "Auto-update off (settings kept in ${AUTO_ENV})"
      if [[ -f "$ENV_FILE" ]]; then motd; fi
      ;;
    status)
      if systemctl is-enabled -q "${AUTO_UNIT}.timer" 2>/dev/null; then
        msg_ok "Auto-update is on"
        systemctl list-timers --no-pager "${AUTO_UNIT}.timer" | head -2
      else
        msg_warn "Auto-update is off (enable: ${NSAPP}-lxc.sh --auto-update on)"
      fi
      echo; echo "Last run:"
      journalctl -u "${AUTO_UNIT}.service" -n 15 --no-pager -o cat 2>/dev/null || true
      ;;
    run) ct_auto_run ;;
  esac
}

ct_auto_run() {
  # What the timer runs: a plain 'update', with an alert when it did not end
  # where it started cleanly. The update runs as its own process so its exit
  # (a failed build, or a rollback) cannot take the alert down with it.
  local before after log rc
  trap - ERR                                  # a failed update is reported below, not traced
  before="$(cat "$VERSION_FILE" 2>/dev/null)"
  log="$(mktemp)"
  set +e
  bash "$SELF_INSTALL_PATH" --update-only 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  after="$(cat "$VERSION_FILE" 2>/dev/null)"
  local tail_txt; tail_txt="$(tail -n 15 "$log" | sed -E 's/\x1B\[[0-9;]*m//g')"
  rm -f "$log"

  if [[ $rc -ne 0 ]]; then
    local what="${APP} auto-update failed on $(hostname); still running ${before}"
    grep -q "rolling back" <<<"$tail_txt" && what="${APP} auto-update rolled back on $(hostname); still running ${before}"
    notify "$what" "warning" "${tail_txt}

Details: journalctl -u ${AUTO_UNIT} -n 200"
    exit "$rc"
  fi
  if [[ "$before" != "$after" && "$(auto_env_get NOTIFY_ON_SUCCESS)" == "1" ]]; then
    notify "${APP} updated on $(hostname)" "white_check_mark" "${before} -> ${after}"
  fi
}

# ==============================================================================
#                           HOST-SIDE FUNCTIONS
# ==============================================================================

is_pve_host() { command -v pct >/dev/null 2>&1 && [[ -d /etc/pve ]]; }
ct_exec() { pct exec "$CTID" -- env LANG=C.UTF-8 LC_ALL=C.UTF-8 "$@"; }

host_update() {
  [[ -n "$CTID" ]] || die "Usage: $0 update <CTID>"
  pct status "$CTID" >/dev/null 2>&1 || die "CT ${CTID} does not exist"
  [[ "$(pct status "$CTID")" == "status: running" ]] || pct start "$CTID"
  msg_info "Pushing updater into CT ${CTID}"
  pct push "$CTID" "$0" "$SELF_INSTALL_PATH" --perms 0755
  local extra=()
  [[ "$FORCE" == "1" ]] && extra+=(--force)
  [[ -n "$REF" ]] && extra+=(--ref "$REF")
  [[ "$WITH_COACH" == "1" ]] && extra+=(--with-coach)
  # Only an explicit --repo overrides what the CT remembers in its source.env.
  [[ -n "$REPO_ARG" ]] && extra+=(--repo "$REPO_ARG")
  ct_exec bash "$SELF_INSTALL_PATH" --update-only "${extra[@]}"
}

host_auto() {
  [[ -n "$CTID" ]] || die "Usage: $0 auto-update <CTID> on|off|status"
  pct status "$CTID" >/dev/null 2>&1 || die "CT ${CTID} does not exist"
  [[ "$(pct status "$CTID")" == "status: running" ]] || pct start "$CTID"
  # The timer runs the CT's copy of this script, so ship the current one.
  pct push "$CTID" "$0" "$SELF_INSTALL_PATH" --perms 0755
  local extra=(--auto-update "$AUTO_ACTION")
  [[ -n "$NOTIFY_URL_IN" ]] && extra+=(--notify-url "$NOTIFY_URL_IN")
  ct_exec bash "$SELF_INSTALL_PATH" "${extra[@]}"
}

pick_template() {
  msg_info "Refreshing template catalogue"
  pveam update >/dev/null 2>&1 || true
  local tmpl arch
  arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
  [[ "$arch" == "x86_64" ]] && arch="amd64"
  [[ "$arch" == "aarch64" ]] && arch="arm64"
  for ver in 13 12; do
    tmpl="$(pveam available --section system 2>/dev/null | awk '{print $2}' \
          | grep -E "^debian-${ver}-standard_.*_${arch}\.tar" | sort -V | tail -1 || true)"
    [[ -n "$tmpl" ]] && break
  done
  [[ -n "$tmpl" ]] || die "No Debian 12/13 ${arch} template available (check 'pveam available')"
  if ! pveam list "$TMPL_STORAGE" 2>/dev/null | grep -q "$tmpl"; then
    msg_info "Downloading template ${tmpl} to ${TMPL_STORAGE}"
    pveam download "$TMPL_STORAGE" "$tmpl" >/dev/null
  fi
  msg_ok "Using template ${tmpl}"
  TEMPLATE="${TMPL_STORAGE}:vztmpl/${tmpl}"
}

host_create() {
  [[ $EUID -eq 0 ]] || die "Run as root on the Proxmox host"
  [[ -f "$0" ]] || die "Run this script from a saved file (bash opengym-lxc.sh); it copies itself into the container."
  header

  [[ -n "$CTID" ]] || CTID="$(pvesh get /cluster/nextid)"
  pct status "$CTID" >/dev/null 2>&1 && die "CT ${CTID} already exists"
  [[ -n "$STORAGE" ]]      || STORAGE="$(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')"
  [[ -n "$TMPL_STORAGE" ]] || TMPL_STORAGE="$(pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active"{print $1; exit}')"
  [[ -n "$STORAGE" ]]      || die "No storage with 'Container' content found (--storage)"
  [[ -n "$TMPL_STORAGE" ]] || die "No storage with 'Container template' content found"

  local net="name=eth0,bridge=${BRIDGE},ip=${NET_IP}"
  [[ "$NET_IP" != "dhcp" && -n "$NET_GW" ]] && net+=",gw=${NET_GW}"
  [[ -n "$VLAN" ]] && net+=",tag=${VLAN}"

  echo
  echo -e "${BOLD}Container to create${CL}"
  printf "  %-12s %s\n" "CTID"     "$CTID" \
                        "Hostname" "$HN" \
                        "OS"       "Debian (latest standard template)" \
                        "Cores"    "$CORES" \
                        "RAM/Swap" "${RAM} MB / ${SWAP} MB" \
                        "Disk"     "${DISK} GB on ${STORAGE}" \
                        "Network"  "$net" \
                        "Type"     "$([[ $UNPRIV == 1 ]] && echo unprivileged || echo privileged)" \
                        "Source"   "$REPO" \
                        "Version"  "${REF:-$([[ "$REPO" == "$UPSTREAM_REPO" ]] && echo "latest release" || echo main)}" \
                        "Auto-upd" "$([[ "$AUTO_ACTION" == "on" ]] && echo nightly || echo off)" \
                        "AI Coach" "$([[ $WITH_COACH == 1 ]] && echo "Claude Agent SDK included" || echo "API-key providers only (add --with-coach for subscription)")" \
                        "RP_ID"    "${RP_ID:-<container IP>  (passkeys need HTTPS + a hostname — edit later in ${ENV_FILE})}" \
                        "ORIGIN"   "${ORIGIN:-http://<container IP>}"
  echo
  if [[ "$ASSUME_YES" != "1" ]]; then
    read -r -p "Proceed? [y/N] " a; [[ "${a,,}" == "y" ]] || { echo "Aborted."; exit 0; }
  fi

  pick_template

  msg_info "Creating LXC ${CTID}"
  local pw_args=()
  [[ -n "$PASSWORD" ]] && pw_args=(--password "$PASSWORD")
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$HN" --cores "$CORES" --memory "$RAM" --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK}" --net0 "$net" \
    --unprivileged "$UNPRIV" --features nesting=1 \
    --onboot "$ONBOOT" --ostype debian --tags "${NSAPP};fitness" \
    --description "${APP} — https://github.com/${REPO}
Update: bash opengym-lxc.sh update ${CTID}  (or run 'update' inside)" \
    "${pw_args[@]}" >/dev/null
  msg_ok "Created LXC ${CTID}"

  msg_info "Starting container and waiting for network"
  pct start "$CTID"
  local i
  for i in $(seq 1 30); do
    pct exec "$CTID" -- bash -c "getent hosts deb.debian.org >/dev/null 2>&1" && break
    sleep 2
  done
  pct exec "$CTID" -- bash -c "getent hosts deb.debian.org >/dev/null 2>&1" \
    || die "Container has no network/DNS after 60 s — check bridge/IP settings"
  msg_ok "Container is online"

  msg_info "Running installer inside CT ${CTID}"
  pct push "$CTID" "$0" "$SELF_INSTALL_PATH" --perms 0755
  local extra=(--repo "$REPO")
  [[ -n "$RP_ID" ]]  && extra+=(--rp-id "$RP_ID")
  [[ -n "$ORIGIN" ]] && extra+=(--origin "$ORIGIN")
  [[ -n "$REF" ]]    && extra+=(--ref "$REF")
  [[ "$WITH_COACH" == "1" ]] && extra+=(--with-coach)
  [[ "$RP_NAME" != "$APP" ]] && extra+=(--rp-name "$RP_NAME")
  [[ "$AUTO_ACTION" == "on" ]] && extra+=(--auto-update on)
  [[ -n "$NOTIFY_URL_IN" ]] && extra+=(--notify-url "$NOTIFY_URL_IN")
  ct_exec bash "$SELF_INSTALL_PATH" --install-only "${extra[@]}"

  local ip; ip="$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  msg_ok "${BOLD}${APP} is ready${CL}"
  echo "   URL      : http://${ip}/"
  echo "   Update   : bash $0 update ${CTID}     (or 'update' inside the CT)"
  echo "   Auto     : bash $0 auto-update ${CTID} on [--notify-url URL]"
  echo "   Config   : ${ENV_FILE} inside the CT"
  echo "   Data     : ${DATA_DIR} inside the CT — back it up (vzdump covers it too)"
  echo
  echo "   Passkey sign-in needs HTTPS and a real hostname. Put a reverse proxy in front,"
  echo "   then set RP_ID/ORIGIN in ${ENV_FILE} and 'systemctl restart ${SERVICE}'."
  echo "   Guest mode (\"Continue without account\") works over plain HTTP on the LAN."
}

# ==============================================================================
#                                  DISPATCH
# ==============================================================================
case "$MODE" in
  ct-install)   ct_install ;;
  ct-update)    ct_update ;;
  host-update)  is_pve_host || die "'update <CTID>' must run on the Proxmox host (inside the CT just run: update)"; host_update ;;
  host-auto)    is_pve_host || die "'auto-update <CTID>' runs on the Proxmox host (inside the CT: --auto-update on|off|status)"; host_auto ;;
  "")
    if is_pve_host; then host_create
    elif [[ -n "$AUTO_ACTION" ]]; then ct_auto "$AUTO_ACTION"
    elif [[ -f "$VERSION_FILE" ]]; then ct_update
    else ct_install
    fi ;;
esac
