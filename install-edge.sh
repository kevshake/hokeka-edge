#!/usr/bin/env bash
#
# Hokeka Edge — public bootstrap installer
#
# One-liner (token from Console → Edge Nodes → Generate install token):
#   curl -fsSL https://hokeka.com/install-edge.sh | sudo bash -s -- --enrol-token <token>
#
# Same script is published at:
#   https://raw.githubusercontent.com/kevshake/hokeka-edge/main/install-edge.sh
#
# Downloads a pinned Edge release from the PUBLIC GitHub repo kevshake/hokeka-edge
# (no GitHub token required), verifies the detached signature over SHA256SUMS against the pinned
# release key and then the SHA-256 checksums, installs to /opt/hokeka, registers systemd, and redeems the install token
# against the Control Plane so the node appears online after enrolment.
#
# Options:
#   --enrol-token <token>     Required for first install (unless --upgrade/--uninstall)
#   --control-plane <url>     Default https://aml.hokeka.com
#   --version <semver>        Pin a release (default: latest)
#   --upgrade                 Re-download and reinstall the same or newer version
#   --uninstall               Stop services and remove /opt/hokeka (keeps ledger data unless --purge)
#   --purge                   With --uninstall, also remove data volumes
#   --edgeid <id>             Optional preferred edge id
#   --display-name <name>     Optional display name hint for redeem
#   --native                  Prefer native JVM install (default: container when Docker available)
#   --container               Force container mode (the default of the release installer)
#   --install-dir <dir>       Install root (default /opt/hokeka; must be absolute, not /)
#   --skip-preflight         Skip outbound HTTPS / resource checks (not recommended)
#   --insecure-skip-signature Skip detached signature verification (internal mirrors only; never needed
#                             for the official releases, which are signed by the key pinned in this script)
#   -h | --help               Show this help
#
# Outbound HTTPS needed: the Control Plane (aml.hokeka.com), api.github.com, github.com and its
# release-asset CDN (release-assets.githubusercontent.com / objects.githubusercontent.com), plus
# Docker Hub for the container images. HOKEKA_RELEASES_REPO overrides the release repo (forks).
#
set -euo pipefail

# ── defaults ─────────────────────────────────────────────────────────────────────────────────────
HOKEKA_RELEASES_REPO="${HOKEKA_RELEASES_REPO:-kevshake/hokeka-edge}"
HOKEKA_CONTROL_PLANE="${HOKEKA_CONTROL_PLANE:-https://aml.hokeka.com}"
HOKEKA_INSTALL_DIR="${HOKEKA_INSTALL_DIR:-/opt/hokeka}"
HOKEKA_VERSION=""
HOKEKA_ENROL_TOKEN=""
HOKEKA_EDGE_ID=""
HOKEKA_DISPLAY_NAME=""
HOKEKA_MODE="auto"          # auto | native | container
HOKEKA_ACTION="install"     # install | upgrade | uninstall
HOKEKA_PURGE=0
HOKEKA_SKIP_PREFLIGHT=0
HOKEKA_SKIP_SIGNATURE=0
HOKEKA_MIN_RAM_MB=2048
HOKEKA_MIN_DISK_MB=10240

# ── pinned release signing key ───────────────────────────────────────────────────────────────────
# The same trust anchor as edge-host/deploy/install.sh: SHA256SUMS.asc must be signed by this key.
# Pinned by scripts/generate-release-key.sh --pin (which updates every copy of this script). While
# it is empty this bootstrap cannot verify signatures and stops, unless the operator passes
# --insecure-skip-signature; it never reports a check it did not make.
HOKEKA_SIGNING_FINGERPRINT="4C26B610FE78132181C86FD9E099931D5D0BB70A"
HOKEKA_SIGNING_KEY="-----BEGIN PGP PUBLIC KEY BLOCK-----

mDMEawX8yxYJKwYBBAHaRw8BAQdAwcfCxElh3EDUxiRW/ZpsIGheUZeRUO7Uy73P
yn9Hx2+0NUhva2VrYSBFZGdlIFJlbGVhc2UgU2lnbmluZyBLZXkgPHJlbGVhc2Vz
QGhva2VrYS5jb20+iJYEExYKAD4WIQRMJrYQ/ngTIYHIb9ngmZMdXQu3CgUCawX8
ywIbAwUJBaOagAULCQgHAgYVCgkICwIEFgIDAQIeAQIXgAAKCRDgmZMdXQu3CtSV
AQC5mV70RoZqn9iZdt6eDrxapXTb4DuN/1FheIR2PedVZQEAnXokNbxAoHe65j0y
YIVFir+KUyID+8RQA9UIpqn0nQA=
=dNwZ
-----END PGP PUBLIC KEY BLOCK-----"

# ── logging ──────────────────────────────────────────────────────────────────────────────────────
# Print an informational progress line.
log()  { printf '\033[0;36m[hokeka]\033[0m %s\n' "$*"; }
# Print a success line.
ok()   { printf '  \033[0;32m[OK]\033[0m %s\n' "$*"; }
# Print a non-fatal warning.
warn() { printf '  \033[0;33m[!]\033[0m %s\n' "$*"; }
# Print an error and exit non-zero.
die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }
# Show usage from the header comment and exit.
# When piped (curl … | bash) $0 is "bash", so fall back to a built-in flag list.
usage() {
  if [ -r "$0" ] && grep -q 'public bootstrap installer' "$0" 2>/dev/null; then
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
  else
    printf '%s\n' "Hokeka Edge public bootstrap installer" \
      "Usage: install-edge.sh --enrol-token <token> [--control-plane <url>] [--version <semver>]" \
      "       [--edgeid <id>] [--display-name <name>] [--native|--container] [--install-dir <dir>]" \
      "       [--skip-preflight] [--insecure-skip-signature]" \
      "       install-edge.sh --upgrade [--version <semver>] | --uninstall [--purge]"
  fi
  exit 0
}

# ── argument parsing ─────────────────────────────────────────────────────────────────────────────
# Parse CLI flags into the HOKEKA_* globals above.
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --enrol-token|--enroll-token) HOKEKA_ENROL_TOKEN="${2:-}"; shift 2 ;;
      --control-plane) HOKEKA_CONTROL_PLANE="${2:-}"; shift 2 ;;
      --version) HOKEKA_VERSION="${2:-}"; shift 2 ;;
      --edgeid|--edge-id) HOKEKA_EDGE_ID="${2:-}"; shift 2 ;;
      --display-name) HOKEKA_DISPLAY_NAME="${2:-}"; shift 2 ;;
      --native) HOKEKA_MODE="native"; shift ;;
      --container) HOKEKA_MODE="container"; shift ;;
      --upgrade) HOKEKA_ACTION="upgrade"; shift ;;
      --uninstall) HOKEKA_ACTION="uninstall"; shift ;;
      --purge) HOKEKA_PURGE=1; shift ;;
      --skip-preflight) HOKEKA_SKIP_PREFLIGHT=1; shift ;;
      --insecure-skip-signature) HOKEKA_SKIP_SIGNATURE=1; shift ;;
      --install-dir) HOKEKA_INSTALL_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown option: $1 (use --help)" ;;
    esac
  done
  # Uninstall runs rm -rf under this path, so an empty or root value must never get through.
  case "$HOKEKA_INSTALL_DIR" in
    /*[!/]*) ;;
    *) die "--install-dir must be an absolute path other than / (got '${HOKEKA_INSTALL_DIR}')" ;;
  esac
}

# ── platform detection ───────────────────────────────────────────────────────────────────────────
# Detect Linux distro family, package manager, CPU arch and libc.
detect_platform() {
  [ "$(uname -s)" = "Linux" ] || die "This bootstrap supports Linux only. On Windows use install.ps1 from the release assets."
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64) ARCH_KEY="x86_64"; GH_ARCH="amd64" ;;
    aarch64|arm64) ARCH_KEY="aarch64"; GH_ARCH="arm64" ;;
    *) die "unsupported architecture: $ARCH (need amd64 or arm64)" ;;
  esac

  DISTRO="unknown"; PKG=""; LIBC="glibc"
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO="${ID:-unknown}"
  fi
  for m in apt-get dnf yum zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then PKG="$m"; break; fi
  done
  if ldd --version 2>&1 | head -1 | grep -qi musl; then LIBC="musl"; fi
  log "Detected ${DISTRO} · ${ARCH_KEY} · ${LIBC} · pkg=${PKG:-none}"
}

# Require root (systemd + package installs).
require_root() {
  [ "$(id -u)" -eq 0 ] || die "please run as root (sudo)."
}

# Honour HTTP(S)_PROXY for curl and package managers.
apply_proxy_env() {
  if [ -n "${HTTPS_PROXY:-${https_proxy:-}}" ] || [ -n "${HTTP_PROXY:-${http_proxy:-}}" ]; then
    log "Using proxy HTTP_PROXY=${HTTP_PROXY:-${http_proxy:-}} HTTPS_PROXY=${HTTPS_PROXY:-${https_proxy:-}}"
    export http_proxy https_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY no_proxy
  fi
}

# ── dependency install ───────────────────────────────────────────────────────────────────────────
# Install curl, ca-certificates, openssl, jq and coreutils on first run.
install_host_deps() {
  local pkgs=()
  case "$PKG" in
    apt-get)
      pkgs=(curl ca-certificates openssl jq coreutils gnupg)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
      ;;
    dnf)
      pkgs=(curl ca-certificates openssl jq coreutils gnupg2)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      pkgs=(curl ca-certificates openssl jq coreutils gnupg2)
      yum install -y "${pkgs[@]}"
      ;;
    zypper)
      pkgs=(curl ca-certificates openssl jq coreutils gpg2)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    apk)
      pkgs=(curl ca-certificates openssl jq coreutils gnupg)
      apk add --no-cache "${pkgs[@]}"
      ;;
    *)
      command -v curl >/dev/null 2>&1 || die "curl is required and no package manager was found"
      warn "unknown package manager — assuming curl/openssl already present"
      ;;
  esac
  command -v curl >/dev/null 2>&1 || die "curl missing after dependency install"
  command -v openssl >/dev/null 2>&1 || die "openssl missing after dependency install"
  ok "Host dependencies installed"
}

# ── preflight ────────────────────────────────────────────────────────────────────────────────────
# Probe outbound HTTPS to the Control Plane and GitHub download hosts; check disk/RAM; warn on SELinux.
preflight() {
  [ "$HOKEKA_SKIP_PREFLIGHT" = "1" ] && { warn "preflight skipped"; return 0; }

  local cp_host gh_host
  cp_host="$(printf '%s' "$HOKEKA_CONTROL_PLANE" | sed -E 's#^https?://##' | cut -d/ -f1)"
  gh_host="github.com"
  log "Preflight: Control Plane ${cp_host}, GitHub ${gh_host}, disk/RAM"

  if ! curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null \
      "${HOKEKA_CONTROL_PLANE%/}/api/v1/actuator/health" \
      && ! curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null \
      "${HOKEKA_CONTROL_PLANE%/}/"; then
    warn "Could not reach Control Plane at ${HOKEKA_CONTROL_PLANE} — enrolment may fail. Check firewall / HTTPS_PROXY."
  else
    ok "Control Plane reachable"
  fi

  if ! curl -fsSL --connect-timeout 10 --max-time 30 -o /dev/null \
      "https://api.github.com/repos/${HOKEKA_RELEASES_REPO}/releases/latest"; then
    die "Cannot reach GitHub Releases for ${HOKEKA_RELEASES_REPO}. Check outbound HTTPS / HTTPS_PROXY."
  fi
  ok "GitHub Releases reachable"

  local ram_mb disk_mb
  ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
  disk_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
  [ "$ram_mb" -ge "$HOKEKA_MIN_RAM_MB" ] || warn "RAM ${ram_mb} MiB < recommended ${HOKEKA_MIN_RAM_MB} MiB"
  [ "$disk_mb" -ge "$HOKEKA_MIN_DISK_MB" ] || warn "Free disk ${disk_mb} MiB < recommended ${HOKEKA_MIN_DISK_MB} MiB"

  if command -v getenforce >/dev/null 2>&1; then
    local selinux
    selinux="$(getenforce 2>/dev/null || true)"
    case "$selinux" in
      Enforcing)
        warn "SELinux is Enforcing (${DISTRO}). If the Edge service fails to start, allow container/systemd access or review audit2allow tips in the install docs."
        ;;
      *) ok "SELinux: ${selinux:-unknown}" ;;
    esac
  fi
}

# ── release download ─────────────────────────────────────────────────────────────────────────────
# Resolve the release tag: explicit --version, else GitHub /releases/latest.
resolve_version() {
  if [ -n "$HOKEKA_VERSION" ]; then
    RESOLVED_VERSION="${HOKEKA_VERSION#v}"
    return 0
  fi
  local json tag
  json="$(curl -fsSL "https://api.github.com/repos/${HOKEKA_RELEASES_REPO}/releases/latest")" \
    || die "could not resolve latest release for ${HOKEKA_RELEASES_REPO}"
  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$tag" ] || die "latest release for ${HOKEKA_RELEASES_REPO} has no tag_name — cut a v* release first"
  RESOLVED_VERSION="${tag#v}"
  log "Resolved latest version: ${RESOLVED_VERSION}"
}

# Download one release asset into DEST_DIR. Fails the install (die) on any HTTP error.
# download_asset <name>
download_asset() {
  local name="$1"
  local url="https://github.com/${HOKEKA_RELEASES_REPO}/releases/download/v${RESOLVED_VERSION}/${name}"
  curl -fsSL -o "${DEST_DIR}/${name}" "$url" || die "download failed: ${name} (${url})"
}

# Print the SHA-256 that the (already signature-verified) SHA256SUMS lists for <name>, or nothing.
# Accepts both "hash  name" and "hash *name" rows.
sums_hash() { # sums_hash <name>
  awk -v n="$1" '{ f = $2; sub(/^[*]/, "", f); if (f == n) { print $1; exit } }' "${DEST_DIR}/SHA256SUMS"
}

# Download <name> and check it against its SHA256SUMS row. A file that SHA256SUMS does not list is
# refused: the signature only vouches for what is listed, so an unlisted file is unauthenticated.
fetch_verified() { # fetch_verified <name>
  local name="$1" want got
  want="$(sums_hash "$name")"
  [ -n "$want" ] || die "${name} is not listed in the signed SHA256SUMS of v${RESOLVED_VERSION} — refusing it"
  download_asset "$name"
  got="$(sha256sum "${DEST_DIR}/${name}" | awk '{print $1}')"
  [ "$got" = "$want" ] || die "checksum mismatch for ${name} (expected ${want} got ${got})"
  ok "checksum ${name}"
}

# Authenticate SHA256SUMS BEFORE any digest in it is trusted.
verify_sums_signature() {
  [ -s "${DEST_DIR}/SHA256SUMS" ] || die "SHA256SUMS missing from release v${RESOLVED_VERSION}"
  if [ "$HOKEKA_SKIP_SIGNATURE" = "1" ]; then
    warn "signature verification skipped (--insecure-skip-signature)"
    return 0
  fi
  verify_signature "${DEST_DIR}/SHA256SUMS" "${DEST_DIR}/SHA256SUMS.asc"
}

# Verifies the detached GPG signature over SHA256SUMS against the pinned release key, fail-closed
# like edge-host/deploy/install.sh: no pinned key, a missing or bad signature all abort. Skipping
# requires the operator to pass --insecure-skip-signature (handled by the caller).
verify_signature() { # verify_signature <SHA256SUMS> <SHA256SUMS.asc>
  local sums="$1" sig="$2" gnupg_home
  [ -n "$HOKEKA_SIGNING_KEY" ] || die \
"this bootstrap has no pinned release signing key, so it cannot verify the authenticity of
       v${RESOLVED_VERSION} from ${HOKEKA_RELEASES_REPO}. Obtain an official signed bootstrap from Hokeka,
       or — only if you already trust this artifact source by other means — re-run with
       --insecure-skip-signature."
  [ -s "$sig" ] || die "SHA256SUMS.asc is missing from v${RESOLVED_VERSION} — refusing unsigned artifacts"
  command -v gpg >/dev/null 2>&1 || die "gpg is required to verify the release signature — install gnupg and re-run"
  gnupg_home="$(mktemp -d)"
  chmod 700 "$gnupg_home"
  printf '%s' "$HOKEKA_SIGNING_KEY" | gpg --homedir "$gnupg_home" --batch --quiet --import 2>/dev/null \
    || { rm -rf "$gnupg_home"; die "the pinned signing key is malformed — refusing to continue"; }
  if [ -n "$HOKEKA_SIGNING_FINGERPRINT" ] && ! gpg --homedir "$gnupg_home" --list-keys --with-colons 2>/dev/null \
      | awk -F: '/^fpr:/ {print $10}' | grep -qx "$HOKEKA_SIGNING_FINGERPRINT"; then
    rm -rf "$gnupg_home"
    die "the pinned key does not match the pinned fingerprint $HOKEKA_SIGNING_FINGERPRINT — refusing to continue"
  fi
  if ! gpg --homedir "$gnupg_home" --batch --quiet --verify "$sig" "$sums" 2>/dev/null; then
    rm -rf "$gnupg_home"
    die "SHA256SUMS FAILED SIGNATURE VERIFICATION for v${RESOLVED_VERSION} — refusing to install"
  fi
  rm -rf "$gnupg_home"
  ok "SHA256SUMS signature verified against the pinned Hokeka release key"
}

# Fetch the release assets needed for this arch into DEST_DIR: signature over SHA256SUMS first,
# then every artifact must be listed in it and match its digest.
fetch_release() {
  DEST_DIR="$(mktemp -d /tmp/hokeka-edge.XXXXXX)"
  chmod 700 "$DEST_DIR"
  log "Downloading Edge v${RESOLVED_VERSION} from github.com/${HOKEKA_RELEASES_REPO}"
  download_asset "SHA256SUMS"
  if [ "$HOKEKA_SKIP_SIGNATURE" != "1" ]; then
    download_asset "SHA256SUMS.asc"
  fi
  verify_sums_signature
  fetch_verified "edge-host.jar"
  fetch_verified "install.sh"
  # The offline inner installer runs compose up from its own directory and sizes
  # aerospike/aerospike.conf in place, so both ship as signed assets listed in SHA256SUMS.
  fetch_verified "docker-compose.yml"
  fetch_verified "aerospike.conf"
  # The native core is optional (the Edge falls back to the Java interpreter); fetch it only when
  # this release lists one for the host.
  local core="libedge_engine-linux-${ARCH_KEY}.so"
  if [ "$LIBC" = "musl" ] && [ "$ARCH_KEY" = "x86_64" ] && [ "$HOKEKA_MODE" = "native" ]; then
    core="libedge_engine-linux-x86_64-musl.so"
  fi
  if [ -n "$(sums_hash "$core")" ]; then
    fetch_verified "$core"
  else
    warn "v${RESOLVED_VERSION} ships no ${core}; the Edge will use its Java interpreter"
  fi
  chmod +x "${DEST_DIR}/install.sh"
}

# ── redeem install token ─────────────────────────────────────────────────────────────────────────
# Exchange the one-time install token for pspId + enrollment code + suggested edge id.
redeem_token() {
  [ -n "$HOKEKA_ENROL_TOKEN" ] || die "--enrol-token is required for install (mint one in Console → Edge Nodes)"
  local hostname body resp
  hostname="$(hostname -f 2>/dev/null || hostname || echo unknown)"
  body="$(printf '{"token":"%s","hostname":"%s","edgeId":"%s","displayName":"%s"}' \
    "$(json_escape "$HOKEKA_ENROL_TOKEN")" \
    "$(json_escape "$hostname")" \
    "$(json_escape "${HOKEKA_EDGE_ID}")" \
    "$(json_escape "${HOKEKA_DISPLAY_NAME}")")"

  log "Redeeming install token at ${HOKEKA_CONTROL_PLANE}"
  resp="$(curl -fsSL -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json' \
    --connect-timeout 15 --max-time 60 \
    -d "$body" \
    "${HOKEKA_CONTROL_PLANE%/}/api/v1/edge/install-tokens/redeem")" \
    || die "token redeem failed — check token validity, Control Plane URL, and outbound HTTPS"

  REDEEM_PSP_ID="$(json_field "$resp" pspId)"
  REDEEM_ENROLL_CODE="$(json_field "$resp" enrollmentCode)"
  REDEEM_EDGE_ID="$(json_field "$resp" suggestedEdgeId)"
  REDEEM_CP="$(json_field "$resp" controlPlaneUrl)"
  [ -n "$REDEEM_PSP_ID" ] && [ -n "$REDEEM_ENROLL_CODE" ] \
    || die "redeem response missing pspId/enrollmentCode: $resp"
  [ -n "$HOKEKA_EDGE_ID" ] || HOKEKA_EDGE_ID="$REDEEM_EDGE_ID"
  [ -n "$HOKEKA_EDGE_ID" ] || HOKEKA_EDGE_ID="edge-${REDEEM_PSP_ID}-$(hostname -s 2>/dev/null || echo node)"
  [ -n "$REDEEM_CP" ] && HOKEKA_CONTROL_PLANE="$REDEEM_CP"
  ok "Token redeemed — PSP ${REDEEM_PSP_ID}, edge id ${HOKEKA_EDGE_ID}"
}

# Escape a string for embedding in a JSON string value.
json_escape() {
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
    || printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Extract a top-level JSON string/number field without requiring jq.
json_field() {
  local json="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r --arg f "$field" '.[$f] // empty'
    return 0
  fi
  printf '%s' "$json" | python3 -c "import json,sys; d=json.load(sys.stdin); v=d.get('$field'); print('' if v is None else v)" 2>/dev/null \
    || printf '%s' "$json" | sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -1
}

# ── install / upgrade / uninstall ────────────────────────────────────────────────────────────────
# Stage artifacts beside install.sh (offline mode) and invoke it with enrolment params.
run_inner_install() {
  local staging="${HOKEKA_INSTALL_DIR}/release-staging"
  mkdir -p "$staging"
  # install.sh --offline copies edge-host*.jar and libedge_engine*.so from $HERE (its directory).
  cp -f "${DEST_DIR}/install.sh" "$staging/install.sh"
  chmod +x "$staging/install.sh"
  cp -f "${DEST_DIR}/edge-host.jar" "$staging/edge-host.jar"
  cp -f "${DEST_DIR}/SHA256SUMS" "$staging/SHA256SUMS" 2>/dev/null || true
  cp -f "${DEST_DIR}/docker-compose.yml" "$staging/docker-compose.yml"
  mkdir -p "$staging/aerospike"
  cp -f "${DEST_DIR}/aerospike.conf" "$staging/aerospike/aerospike.conf"
  # Normalise the native library name the offline installer looks for (libedge_engine*.so).
  local lib
  for lib in "${DEST_DIR}"/libedge_engine*.so; do
    [ -f "$lib" ] || continue
    cp -f "$lib" "$staging/$(basename "$lib")"
  done
  [ -x "$staging/install.sh" ] || die "release is missing install.sh"
  [ -s "$staging/edge-host.jar" ] || die "release is missing edge-host.jar"
  [ -s "$staging/docker-compose.yml" ] || die "release is missing docker-compose.yml"
  [ -s "$staging/aerospike/aerospike.conf" ] || die "release is missing aerospike.conf"

  local args=(
    --pspid "$REDEEM_PSP_ID"
    --edgeid "$HOKEKA_EDGE_ID"
    --controlplane "$HOKEKA_CONTROL_PLANE"
    --version "$RESOLVED_VERSION"
    --offline
  )
  if [ -n "$REDEEM_ENROLL_CODE" ]; then
    args+=(--enrollment-code "$REDEEM_ENROLL_CODE")
  fi
  if [ "$HOKEKA_MODE" = "native" ]; then
    args+=(--native)
  fi
  # The artifacts were verified above (signature, or the operator's --insecure-skip-signature, then
  # checksums); the inner
  # installer runs offline on those same files, so it does not verify them a second time.
  args+=(--insecure-skip-signature)

  log "Running release installer (offline) from ${staging}"
  (
    cd "$staging"
    bash ./install.sh "${args[@]}"
  )

  mkdir -p "${HOKEKA_INSTALL_DIR}/etc"
  cat > "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env" <<EOF
HOKEKA_CONTROL_PLANE=${HOKEKA_CONTROL_PLANE}
HOKEKA_RELEASES_REPO=${HOKEKA_RELEASES_REPO}
HOKEKA_VERSION=${RESOLVED_VERSION}
HOKEKA_PSP_ID=${REDEEM_PSP_ID}
HOKEKA_EDGE_ID=${HOKEKA_EDGE_ID}
HOKEKA_ENROLL_CODE=${REDEEM_ENROLL_CODE}
EOF
  chmod 600 "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env"
  ok "Edge installed (v${RESOLVED_VERSION})"
}

# Reload previously saved bootstrap.env for upgrade paths.
load_bootstrap_env() {
  local f="${HOKEKA_INSTALL_DIR}/etc/bootstrap.env"
  [ -s "$f" ] || die "no existing install at ${HOKEKA_INSTALL_DIR} (missing etc/bootstrap.env)"
  # shellcheck disable=SC1090
  . "$f"
  HOKEKA_CONTROL_PLANE="${HOKEKA_CONTROL_PLANE}"
  REDEEM_PSP_ID="${HOKEKA_PSP_ID}"
  HOKEKA_EDGE_ID="${HOKEKA_EDGE_ID}"
  REDEEM_ENROLL_CODE="${HOKEKA_ENROLL_CODE:-}"
}

# Stop services and remove the install tree; optionally purge data.
do_uninstall() {
  require_root
  log "Uninstalling Hokeka Edge from ${HOKEKA_INSTALL_DIR}"
  systemctl stop hokeka-edge 2>/dev/null || true
  systemctl disable hokeka-edge 2>/dev/null || true
  rm -f /etc/systemd/system/hokeka-edge.service
  systemctl daemon-reload 2>/dev/null || true
  if [ "$HOKEKA_PURGE" = "1" ]; then
    rm -rf "$HOKEKA_INSTALL_DIR"
    ok "Removed ${HOKEKA_INSTALL_DIR} (purged)"
  else
    rm -rf "${HOKEKA_INSTALL_DIR}/release-staging" "${HOKEKA_INSTALL_DIR}/bin" 2>/dev/null || true
    warn "Left data under ${HOKEKA_INSTALL_DIR}/data (use --purge to delete)"
  fi
}

# Upgrade: re-fetch release and re-run install.sh offline without consuming a new token.
do_upgrade() {
  require_root
  apply_proxy_env
  detect_platform
  install_host_deps
  load_bootstrap_env
  # On upgrade the node is already enrolled: reuse the enrollment code saved at install time
  # (HOKEKA_ENROLL_CODE in bootstrap.env) or the one in edge.env so a still-PENDING node can
  # activate. Never invent a placeholder code — an ACTIVE node does not need one.
  if [ -s "${HOKEKA_INSTALL_DIR}/edge.env" ]; then
    existing_code="$(grep -E '^EDGE_ENROLLMENT_CODE=' "${HOKEKA_INSTALL_DIR}/edge.env" | head -1 | cut -d= -f2- || true)"
    [ -n "$existing_code" ] && REDEEM_ENROLL_CODE="$existing_code"
  fi
  if [ -z "$HOKEKA_VERSION" ]; then
    resolve_version
  else
    RESOLVED_VERSION="${HOKEKA_VERSION#v}"
  fi
  preflight
  fetch_release
  run_inner_install
  ok "Upgrade to v${RESOLVED_VERSION} complete"
}

# First-time install path: deps → preflight → download → redeem → install.
do_install() {
  # Fail before installing packages or downloading a release when the token is missing.
  [ -n "$HOKEKA_ENROL_TOKEN" ] || die "--enrol-token is required for install (mint one in Console → Edge Nodes)"
  require_root
  apply_proxy_env
  detect_platform
  install_host_deps
  resolve_version
  preflight
  fetch_release
  redeem_token
  run_inner_install
  log "Next: watch the Edge Nodes page — the node should move to Active after enrolment completes."
  log "Docs: https://docs.hokeka.com/docs/06-edge-public-install"
}

# Entrypoint: dispatch install / upgrade / uninstall.
main() {
  parse_args "$@"
  case "$HOKEKA_ACTION" in
    uninstall) do_uninstall ;;
    upgrade) do_upgrade ;;
    install) do_install ;;
    *) die "unknown action: $HOKEKA_ACTION" ;;
  esac
}

main "$@"
