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
#   --upgrade                 Reinstall the latest (or --version) release on an enrolled node; reuses
#                             etc/bootstrap.env, but --control-plane/--edgeid/--native/--container win
#   --uninstall               Stop the Edge (compose down / systemd) and remove its program files;
#                             keeps config, secrets, identity and ledger data unless --purge
#   --purge                   With --uninstall, also remove data, secrets and the ledger volume.
#                             Asks you to type DELETE first (read from the terminal, also when piped)
#   --yes                     With --uninstall --purge, skip that question (unattended removal)
#   --self-test               Only run the post-install self-test against the existing install
#   --no-self-test            Do not run the self-test at the end of install / upgrade
#   --edgeid <id>             Optional preferred edge id
#   --display-name <name>     Optional display name hint for redeem
#   --native                  Prefer native JVM install (default: container when Docker available)
#   --container               Force container mode (the default of the release installer)
#   --install-dir <dir>       Install root (default /opt/hokeka; must be absolute, not /)
#   --skip-preflight          Skip the outbound HTTPS, clock, Docker/compose version and resource
#                             checks (not recommended)
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
# What the operator chose explicitly (environment or flags). On --upgrade these win over the values
# saved in etc/bootstrap.env; anything not chosen explicitly comes from that saved file.
EXPLICIT_RELEASES_REPO="${HOKEKA_RELEASES_REPO:-}"
EXPLICIT_CONTROL_PLANE="${HOKEKA_CONTROL_PLANE:-}"
EXPLICIT_EDGE_ID=""
HOKEKA_RELEASES_REPO="${HOKEKA_RELEASES_REPO:-kevshake/hokeka-edge}"
HOKEKA_CONTROL_PLANE="${HOKEKA_CONTROL_PLANE:-https://aml.hokeka.com}"
HOKEKA_INSTALL_DIR="${HOKEKA_INSTALL_DIR:-/opt/hokeka}"
HOKEKA_VERSION=""
HOKEKA_ENROL_TOKEN=""
HOKEKA_EDGE_ID=""
HOKEKA_DISPLAY_NAME=""
HOKEKA_MODE="auto"          # auto | native | container
HOKEKA_ACTION="install"     # install | upgrade | uninstall | selftest
HOKEKA_PURGE=0
HOKEKA_ASSUME_YES=0
HOKEKA_SELF_TEST=1
HOKEKA_SKIP_PREFLIGHT=0
HOKEKA_SKIP_SIGNATURE=0
HOKEKA_MIN_RAM_MB=2048
HOKEKA_MIN_DISK_MB=10240
# Preflight floors (G9). Docker 20.10 is the first engine with the compose v2 plugin; the release
# installer drives the stack with "docker compose" / "podman compose", and the shipped
# docker-compose.yml uses depends_on.required (optional ledger dependency), which needs Compose 2.20.
HOKEKA_MIN_DOCKER="20.10"
HOKEKA_MIN_COMPOSE="2.20"
HOKEKA_MIN_PODMAN="4.7"
# Largest tolerated clock offset from the Control Plane, in seconds. Install tokens, enrolment codes
# and the mTLS client certificate are all time-bound, so a skewed clock fails enrolment opaquely.
HOKEKA_MAX_CLOCK_SKEW="${HOKEKA_MAX_CLOCK_SKEW:-60}"
# Post-install self-test (G8): how long to wait for the Control Plane to authorize the node.
HOKEKA_SELF_TEST_TIMEOUT="${HOKEKA_SELF_TEST_TIMEOUT:-180}"
HOKEKA_SELF_TEST_INTERVAL="${HOKEKA_SELF_TEST_INTERVAL:-15}"
# Where --purge reads its confirmation from. /dev/tty, so it still asks when the script is piped
# into bash (stdin is then the script itself).
HOKEKA_CONFIRM_TTY="${HOKEKA_CONFIRM_TTY:-/dev/tty}"

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
      "       [--skip-preflight] [--insecure-skip-signature] [--no-self-test]" \
      "       install-edge.sh --upgrade [--version <semver>] | --uninstall [--purge [--yes]] | --self-test"
  fi
  exit 0
}

# ── argument parsing ─────────────────────────────────────────────────────────────────────────────
# Parse CLI flags into the HOKEKA_* globals above.
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --enrol-token|--enroll-token) HOKEKA_ENROL_TOKEN="${2:-}"; shift 2 ;;
      --control-plane) HOKEKA_CONTROL_PLANE="${2:-}"; EXPLICIT_CONTROL_PLANE="${2:-}"; shift 2 ;;
      --version) HOKEKA_VERSION="${2:-}"; shift 2 ;;
      --edgeid|--edge-id) HOKEKA_EDGE_ID="${2:-}"; EXPLICIT_EDGE_ID="${2:-}"; shift 2 ;;
      --display-name) HOKEKA_DISPLAY_NAME="${2:-}"; shift 2 ;;
      --native) HOKEKA_MODE="native"; shift ;;
      --container) HOKEKA_MODE="container"; shift ;;
      --upgrade) HOKEKA_ACTION="upgrade"; shift ;;
      --uninstall) HOKEKA_ACTION="uninstall"; shift ;;
      --purge) HOKEKA_PURGE=1; shift ;;
      --yes|-y) HOKEKA_ASSUME_YES=1; shift ;;
      --self-test) HOKEKA_ACTION="selftest"; shift ;;
      --no-self-test) HOKEKA_SELF_TEST=0; shift ;;
      --skip-preflight) HOKEKA_SKIP_PREFLIGHT=1; shift ;;
      --insecure-skip-signature) HOKEKA_SKIP_SIGNATURE=1; shift ;;
      --install-dir) HOKEKA_INSTALL_DIR="${2:-}"; shift 2 ;;
      -h|--help) usage ;;
      *) die "unknown option: $1 (use --help)" ;;
    esac
  done
  # --purge / --yes only mean something to --uninstall; silently ignoring them elsewhere could hide
  # a mistyped command line.
  if [ "$HOKEKA_ACTION" != "uninstall" ] && { [ "$HOKEKA_PURGE" = "1" ] || [ "$HOKEKA_ASSUME_YES" = "1" ]; }; then
    die "--purge and --yes only apply to --uninstall"
  fi
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
    x86_64|amd64) ARCH_KEY="x86_64" ;;
    aarch64|arm64) ARCH_KEY="aarch64" ;;
    *) die "unsupported architecture: $ARCH (need amd64 or arm64)" ;;
  esac

  DISTRO="unknown"; PKG=""; LIBC="glibc"
  if [ -r /etc/os-release ]; then
    # Read ID in a subshell so os-release (VERSION, NAME, ...) never overwrites this script's variables.
    # shellcheck disable=SC1091
    DISTRO="$(. /etc/os-release && printf '%s' "${ID:-unknown}")"
  fi
  for m in apt-get dnf yum zypper apk; do
    if command -v "$m" >/dev/null 2>&1; then PKG="$m"; break; fi
  done
  if ldd --version 2>&1 | head -1 | grep -qi musl; then LIBC="musl"; fi
  log "Detected ${DISTRO} · ${ARCH_KEY} · ${LIBC} · pkg=${PKG:-none}"
  # The musl native core is published for x86_64 only, and the release installer refuses --native on
  # musl/arm64 — but only after the token is redeemed. Refuse it here instead.
  if [ "$HOKEKA_MODE" = "native" ] && [ "$LIBC" = "musl" ] && [ "$ARCH_KEY" != "x86_64" ]; then
    die "--native is not supported on musl with ${ARCH_KEY} (no native core is published for it). Use container mode (drop --native) — the token has NOT been used."
  fi
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

  check_clock_skew
  check_container_versions
}

# True when dotted version $1 >= $2, comparing numeric fields left to right ("24.0.7" >= "20.10").
# Anything after the leading digits/dots ("26.1.3-1.el9", "v2.24.5") is ignored.
version_ge() { # version_ge <have> <need>
  local have need i h n
  have="$(printf '%s' "$1" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//')"
  need="$(printf '%s' "$2" | sed -E 's/^[^0-9]*//; s/[^0-9.].*$//')"
  [ -n "$have" ] || return 1
  local IFS=.
  # shellcheck disable=SC2206
  local ha=($have) na=($need)
  for ((i = 0; i < ${#na[@]} || i < ${#ha[@]}; i++)); do
    h="${ha[i]:-0}"; n="${na[i]:-0}"
    h="$((10#${h:-0}))"; n="$((10#${n:-0}))"
    [ "$h" -gt "$n" ] && return 0
    [ "$h" -lt "$n" ] && return 1
  done
  return 0
}

# Convert an HTTP Date header (RFC 1123, always GMT) to epoch seconds with GNU or BusyBox date.
http_date_epoch() { # http_date_epoch "<Tue, 25 Nov 2026 10:00:00 GMT>"
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -D '%a, %d %b %Y %H:%M:%S GMT' -d "$1" +%s 2>/dev/null
}

# G9: the clock must agree with the Control Plane. The offset is measured against the Date header
# of the Control Plane's own HTTPS answer, so it holds whichever NTP daemon (or none) the host runs.
# A measured offset above HOKEKA_MAX_CLOCK_SKEW stops the install here, before the single-use token
# is redeemed. When no Date header can be read, the host's NTP state is reported instead.
check_clock_skew() {
  local hdr server now skew ntp=""
  hdr="$(curl -sS -o /dev/null -D - --connect-timeout 10 --max-time 30 \
      "${HOKEKA_CONTROL_PLANE%/}/api/v1/actuator/health" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^[Dd][Aa][Tt][Ee]:[[:space:]]*//p' | head -1)" || true
  if command -v timedatectl >/dev/null 2>&1; then
    ntp="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  fi
  if [ -n "$hdr" ] && server="$(http_date_epoch "$hdr")" && [ -n "$server" ]; then
    now="$(date -u +%s)"
    skew=$((now - server)); [ "$skew" -lt 0 ] && skew=$((-skew))
    if [ "$skew" -gt "$HOKEKA_MAX_CLOCK_SKEW" ]; then
      die "the system clock is ${skew}s away from the Control Plane (limit ${HOKEKA_MAX_CLOCK_SKEW}s; host $(date -u '+%Y-%m-%dT%H:%M:%SZ'), Control Plane ${hdr}).
       Install tokens, enrolment codes and the Edge's mTLS certificate are time-bound, so enrolment
       would fail. Turn on time sync and re-run — the token has NOT been used:
           timedatectl set-ntp true        # systemd-timesyncd
           chronyc makestep                # chrony"
    fi
    ok "Clock within ${skew}s of the Control Plane (limit ${HOKEKA_MAX_CLOCK_SKEW}s)"
  elif [ "$ntp" = "yes" ]; then
    ok "Clock: NTP synchronized (could not read the Control Plane time to measure the offset)"
  else
    warn "Could not measure the clock offset from the Control Plane${ntp:+ and timedatectl reports NTPSynchronized=${ntp}}. Make sure NTP/chrony keeps this host's time — enrolment and mTLS depend on it."
  fi
}

# G9: container mode needs an engine and compose new enough for the release's docker-compose.yml.
# The release installer prefers docker over podman and drives "docker compose" (the v2 plugin), so
# the checks follow the same order. With no engine at all the release installer installs the
# current Docker itself, so that is reported rather than refused. Native mode needs neither.
check_container_versions() {
  [ "$HOKEKA_MODE" = "native" ] && return 0
  local v engine
  # podman-docker installs a "docker" command that is really podman; judge it by podman's floor.
  if command -v docker >/dev/null 2>&1 && ! docker --version 2>/dev/null | grep -qi podman; then
    engine="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    [ -n "$engine" ] || engine="$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
    version_ge "$engine" "$HOKEKA_MIN_DOCKER" \
      || die "Docker ${engine:-of unknown version} is older than the required ${HOKEKA_MIN_DOCKER}. Upgrade Docker (https://docs.docker.com/engine/install/) or re-run with --native — the token has NOT been used."
    v="$(docker compose version --short 2>/dev/null || true)"
    [ -n "$v" ] || die "Docker is installed but the compose v2 plugin is not ('docker compose version' fails). Install docker-compose-plugin (the standalone docker-compose v1 is not supported) or re-run with --native — the token has NOT been used."
    version_ge "$v" "$HOKEKA_MIN_COMPOSE" \
      || die "Docker Compose ${v} is older than the required ${HOKEKA_MIN_COMPOSE}. Upgrade docker-compose-plugin or re-run with --native — the token has NOT been used."
    ok "Docker ${engine} · Compose ${v}"
  elif command -v podman >/dev/null 2>&1; then
    v="$(podman version --format '{{.Client.Version}}' 2>/dev/null || true)"
    version_ge "$v" "$HOKEKA_MIN_PODMAN" \
      || die "Podman ${v:-of unknown version} is older than the required ${HOKEKA_MIN_PODMAN} (needed for 'podman compose'). Upgrade podman, install Docker, or re-run with --native — the token has NOT been used."
    podman compose version >/dev/null 2>&1 \
      || die "'podman compose' is not available (install podman-compose or docker-compose for it to call), or re-run with --native — the token has NOT been used."
    ok "Podman ${v} with podman compose"
  else
    ok "No container engine yet — the release installer installs the current Docker Engine + compose plugin"
  fi
  # The images (Aerospike, PostgreSQL, the Temurin base of the Edge image) come from Docker Hub on
  # first start. The release installer probes it too, but only after the token is redeemed, so a
  # blocked registry is caught here instead. 401 is Docker Hub's normal "auth required" answer.
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "https://registry-1.docker.io/v2/" || true)"
  case "$code" in
    200|401) ok "Docker Hub reachable (registry-1.docker.io)" ;;
    *) die "cannot reach Docker Hub at registry-1.docker.io (HTTP ${code:-none}). The Edge's container images are pulled from there: allow outbound HTTPS to registry-1.docker.io, auth.docker.io and production.cloudflare.docker.com (or set HTTPS_PROXY), or re-run with --native — the token has NOT been used." ;;
  esac
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
  DEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/hokeka-edge.XXXXXX")"
  chmod 700 "$DEST_DIR"
  log "Downloading Edge v${RESOLVED_VERSION} from github.com/${HOKEKA_RELEASES_REPO}"
  download_asset "SHA256SUMS"
  if [ "$HOKEKA_SKIP_SIGNATURE" != "1" ]; then
    download_asset "SHA256SUMS.asc"
  fi
  verify_sums_signature
  verify_sums_version
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
  # Native mode installs Aerospike CE from the per-distro tarball named (with its SHA-256) in the
  # release's aerospike-artifacts.json; the offline inner installer reads it from its directory.
  if [ "$HOKEKA_MODE" = "native" ]; then
    if [ -n "$(sums_hash "aerospike-artifacts.json")" ]; then
      fetch_verified "aerospike-artifacts.json"
    else
      # Without the manifest the release installer can only install a verified Aerospike from
      # AERO_PACKAGE_URL + AERO_PACKAGE_SHA256; refuse now rather than after the token is redeemed.
      [ -n "${AERO_PACKAGE_URL:-}" ] && [ -n "${AERO_PACKAGE_SHA256:-}" ]         || die "v${RESOLVED_VERSION} lists no aerospike-artifacts.json, so native mode cannot install a verified Aerospike. Export AERO_PACKAGE_URL and AERO_PACKAGE_SHA256 (an Aerospike CE tarball and its SHA-256), or use container mode — the token has NOT been used."
      warn "v${RESOLVED_VERSION} lists no aerospike-artifacts.json; using AERO_PACKAGE_URL with AERO_PACKAGE_SHA256"
    fi
  fi
  chmod +x "${DEST_DIR}/install.sh"
}

# The release tooling (scripts/write-release-sha256sums.sh) writes "# version: v<version>" inside the
# signed SHA256SUMS, binding the signature to one release. Refuse a manifest that names another
# version: that is an older signed release served under this tag. Releases cut before the line
# existed have none and are accepted with a warning.
verify_sums_version() {
  local named
  named="$(sed -n 's/^# version:[[:space:]]*v\{0,1\}\([^[:space:]]*\).*/\1/p' "${DEST_DIR}/SHA256SUMS" | head -1)"
  if [ -z "$named" ]; then
    warn "SHA256SUMS of v${RESOLVED_VERSION} has no version line — its signature is not bound to a version"
    return 0
  fi
  [ "$named" = "$RESOLVED_VERSION" ] \
    || die "SHA256SUMS is signed for v${named}, not the requested v${RESOLVED_VERSION} — refusing it (replayed or mislabelled release)"
  ok "SHA256SUMS is bound to v${named}"
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
  # The signature-verified SHA256SUMS: the inner installer checks aerospike-artifacts.json against it.
  cp -f "${DEST_DIR}/SHA256SUMS" "$staging/SHA256SUMS"
  cp -f "${DEST_DIR}/docker-compose.yml" "$staging/docker-compose.yml"
  mkdir -p "$staging/aerospike"
  cp -f "${DEST_DIR}/aerospike.conf" "$staging/aerospike/aerospike.conf"
  rm -f "$staging/aerospike-artifacts.json"
  if [ -s "${DEST_DIR}/aerospike-artifacts.json" ]; then
    cp -f "${DEST_DIR}/aerospike-artifacts.json" "$staging/aerospike-artifacts.json"
  fi
  # Only this release's core may sit beside the inner installer: a core left by an earlier install
  # (other libc, older version) would otherwise be picked up instead.
  rm -f "$staging"/libedge_engine*.so
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
    --data-dir "$HOKEKA_INSTALL_DIR"
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
  # The bootstrap runs the self-test itself once bootstrap.env is saved (run_self_test below), so a
  # failing self-test never leaves a node that --upgrade / --self-test can no longer find.
  args+=(--no-self-test)

  # Save the enrolment (PSP id, edge id, enrolment code) BEFORE the release installer runs: the
  # token is already redeemed, so if that installer fails (image pull, compose up, a full disk) the
  # operator recovers with --upgrade, which reuses this file, instead of needing a new token.
  mkdir -p "${HOKEKA_INSTALL_DIR}/etc"
  local installed_mode="container"
  [ "$HOKEKA_MODE" = "native" ] && installed_mode="native"
  cat > "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env" <<ENV
HOKEKA_CONTROL_PLANE=${HOKEKA_CONTROL_PLANE}
HOKEKA_RELEASES_REPO=${HOKEKA_RELEASES_REPO}
HOKEKA_VERSION=${RESOLVED_VERSION}
HOKEKA_MODE=${installed_mode}
HOKEKA_PSP_ID=${REDEEM_PSP_ID}
HOKEKA_EDGE_ID=${HOKEKA_EDGE_ID}
HOKEKA_ENROLL_CODE=${REDEEM_ENROLL_CODE}
ENV
  chmod 600 "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env"

  log "Running release installer (offline) from ${staging}"
  if ! ( cd "$staging" && bash ./install.sh "${args[@]}" ); then
    die "the release installer failed (see its output above). The enrolment is saved in ${HOKEKA_INSTALL_DIR}/etc/bootstrap.env,
       so no new token is needed: fix the cause, then re-run
           curl -fsSL https://hokeka.com/install-edge.sh | sudo bash -s -- --upgrade --install-dir ${HOKEKA_INSTALL_DIR}"
  fi
  ok "Edge installed (v${RESOLVED_VERSION}, ${installed_mode} mode)"
}

# Where install.sh keeps the Edge's environment (with EDGE_ENROLLMENT_CODE) for each mode:
# container mode writes .env beside itself (release-staging), native mode writes
# <data-dir>/config/edge.env, and the bootstrap passes --data-dir ${HOKEKA_INSTALL_DIR}.
edge_env_file() { # edge_env_file container|native
  if [ "$1" = "native" ]; then
    printf '%s/config/edge.env' "$HOKEKA_INSTALL_DIR"
  else
    printf '%s/release-staging/.env' "$HOKEKA_INSTALL_DIR"
  fi
}

# Reload the bootstrap.env saved at install time for the upgrade path. The file is parsed as
# KEY=value lines, never sourced, and only fills what the operator did not choose: --control-plane,
# --edgeid, --native/--container and an exported HOKEKA_RELEASES_REPO / HOKEKA_CONTROL_PLANE win.
# The saved HOKEKA_VERSION is the INSTALLED version — it is reported, never used as the target, so
# an upgrade without --version goes to the latest release and --version picks any other.
load_bootstrap_env() {
  local f="${HOKEKA_INSTALL_DIR}/etc/bootstrap.env" key value
  local saved_cp="" saved_repo="" saved_mode="" saved_psp="" saved_edge="" saved_code=""
  [ -s "$f" ] || die "no existing install at ${HOKEKA_INSTALL_DIR} (missing etc/bootstrap.env)"
  INSTALLED_VERSION=""
  while IFS='=' read -r key value || [ -n "$key" ]; do
    case "$key" in
      HOKEKA_CONTROL_PLANE) saved_cp="$value" ;;
      HOKEKA_RELEASES_REPO) saved_repo="$value" ;;
      HOKEKA_VERSION) INSTALLED_VERSION="$value" ;;
      HOKEKA_MODE) saved_mode="$value" ;;
      HOKEKA_PSP_ID) saved_psp="$value" ;;
      HOKEKA_EDGE_ID) saved_edge="$value" ;;
      HOKEKA_ENROLL_CODE) saved_code="$value" ;;
    esac
  done < "$f"
  [ -n "$saved_psp" ] || die "${f} has no HOKEKA_PSP_ID — cannot upgrade this install; reinstall with --enrol-token"
  HOKEKA_CONTROL_PLANE="${EXPLICIT_CONTROL_PLANE:-${saved_cp:-$HOKEKA_CONTROL_PLANE}}"
  HOKEKA_RELEASES_REPO="${EXPLICIT_RELEASES_REPO:-${saved_repo:-$HOKEKA_RELEASES_REPO}}"
  HOKEKA_EDGE_ID="${EXPLICIT_EDGE_ID:-$saved_edge}"
  if [ "$HOKEKA_MODE" = "auto" ]; then
    case "$saved_mode" in native|container) HOKEKA_MODE="$saved_mode" ;; *) HOKEKA_MODE="container" ;; esac
  fi
  REDEEM_PSP_ID="$saved_psp"
  REDEEM_ENROLL_CODE="$saved_code"
  log "Upgrading ${HOKEKA_MODE} install (installed v${INSTALLED_VERSION:-unknown}) — Control Plane ${HOKEKA_CONTROL_PLANE}, releases ${HOKEKA_RELEASES_REPO}"
}

# The container engine's compose command, or nothing when no engine is installed.
compose_cmd() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
  elif command -v docker-compose >/dev/null 2>&1; then
    printf 'docker-compose'
  elif command -v podman >/dev/null 2>&1; then
    printf 'podman compose'
  fi
}

# Value of KEY in an env file written by install.sh, or nothing. Read as text, never sourced.
env_value() { # env_value <file> <KEY>
  [ -s "$1" ] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

# The verdict in a POST /edge/evaluate response, read from stdin. The Edge answers
# {"action":"HOLD","score":…}; "decision" is kept as a fallback for older builds (G16).
edge_verdict() {
  local body v
  body="$(cat)"
  v="$(printf '%s' "$body" | sed -n 's/.*"action"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  [ -n "$v" ] || v="$(printf '%s' "$body" | sed -n 's/.*"decision"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  printf '%s' "$v"
}

# ── post-install self-test (G8) ──────────────────────────────────────────────────────────────────
# Three checks against the Edge's own transaction API, each printed in a PASS/FAIL summary:
#   1. the API answers GET /edge/status over TLS,
#   2. the Control Plane has authorized the node (authorization=active) within the timeout,
#   3. one PAN-free POST /edge/evaluate returns a decision (evaluate → decide → record works).
# Runs after bootstrap.env is saved, so a failure leaves a complete install that can be inspected
# and re-checked with --self-test. Returns non-zero when any check fails.
run_self_test() {
  local mode="${HOKEKA_MODE}" env_file bind port base i status_json="" authorization="" evaluator decision
  [ "$mode" = "native" ] || mode="container"
  env_file="$(edge_env_file "$mode")"
  if [ "$mode" = "container" ]; then
    bind="$(env_value "$env_file" EDGE_BIND)"; port="$(env_value "$env_file" EDGE_API_PORT)"
  else
    bind="$(env_value "$env_file" EDGE_BIND_ADDRESS)"
  fi
  # A wildcard bind is reachable on loopback; the API port defaults to 8443 in both modes.
  case "${bind:-127.0.0.1}" in 0.0.0.0|::|"[::]") bind="127.0.0.1" ;; esac
  base="https://${bind:-127.0.0.1}:${port:-8443}"
  local r_api="FAIL" r_auth="SKIP" r_eval="SKIP" d_api="no answer from ${base}/edge/status" d_auth="" d_eval=""

  log "Self-test: checking the Edge at ${base} (waiting up to ${HOKEKA_SELF_TEST_TIMEOUT}s for authorization)…"
  local deadline=$(( $(date +%s) + HOKEKA_SELF_TEST_TIMEOUT ))
  while :; do
    if status_json="$(curl -kfsS --connect-timeout 5 --max-time 15 "${base}/edge/status" 2>/dev/null)"; then
      r_api="PASS"; d_api="${base}/edge/status answers"
      authorization="$(printf '%s' "$status_json" | sed -n 's/.*"authorization"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [ "$authorization" = "active" ] && break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || break
    sleep "$HOKEKA_SELF_TEST_INTERVAL"
  done

  if [ "$r_api" = "PASS" ]; then
    if [ "$authorization" = "active" ]; then
      evaluator="$(printf '%s' "$status_json" | sed -n 's/.*"evaluator"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      r_auth="PASS"; d_auth="authorized by the Control Plane${evaluator:+ (evaluator ${evaluator})}"
      decision="$(curl -kfsS --connect-timeout 5 --max-time 30 -X POST "${base}/edge/evaluate" \
          -H "Content-Type: application/json" \
          -d "{\"txn_id\":\"selftest-$(date +%s)\",\"amount\":\"100\",\"currency\":\"KES\"}" 2>/dev/null \
        | edge_verdict)" || true
      if [ -n "$decision" ]; then
        r_eval="PASS"; d_eval="PAN-free test evaluation answered ${decision}"
      else
        r_eval="FAIL"; d_eval="POST /edge/evaluate returned no decision"
      fi
    else
      r_auth="FAIL"; d_auth="not authorized after ${HOKEKA_SELF_TEST_TIMEOUT}s (authorization=${authorization:-none})"
    fi
  fi
  [ -n "$d_auth" ] || d_auth="needs a reachable API"
  [ -n "$d_eval" ] || d_eval="needs an authorized node"

  echo
  log "──────────── Self-test summary ────────────"
  printf '  %-4s  %s\n' "$r_api" "Edge API: ${d_api}" "$r_auth" "Enrolment: ${d_auth}" "$r_eval" "Decision path: ${d_eval}"
  if [ "$r_api" = "PASS" ] && [ "$r_auth" = "PASS" ] && [ "$r_eval" = "PASS" ]; then
    ok "Self-test: PASS (3/3) — the Edge is enrolled and answering"
    return 0
  fi
  printf '\033[0;31m[hokeka] Self-test: FAIL\033[0m — the Edge is installed but not yet healthy.\n' >&2
  if [ "$mode" = "container" ]; then
    echo "  Logs:    cd ${HOKEKA_INSTALL_DIR}/release-staging && docker compose logs edge   (podman compose on podman hosts)"
  else
    echo "  Logs:    journalctl -u hokeka-edge -n 100"
  fi
  echo "  Pending: check the node on Console → Edge Nodes; a node stays unauthorized until its enrolment code is accepted."
  echo "  Re-run:  curl -fsSL https://hokeka.com/install-edge.sh | sudo bash -s -- --self-test --install-dir ${HOKEKA_INSTALL_DIR}"
  return 1
}

# --self-test on an existing install: load the saved mode and run only the self-test.
do_self_test() {
  require_root
  local f="${HOKEKA_INSTALL_DIR}/etc/bootstrap.env"
  [ -s "$f" ] || die "no existing install at ${HOKEKA_INSTALL_DIR} (missing etc/bootstrap.env)"
  if [ "$HOKEKA_MODE" = "auto" ]; then
    case "$(env_value "$f" HOKEKA_MODE)" in native) HOKEKA_MODE="native" ;; *) HOKEKA_MODE="container" ;; esac
  fi
  run_self_test || exit 1
}

# Run the self-test at the end of install / upgrade unless --no-self-test; exit 1 when it fails.
finish_with_self_test() {
  if [ "$HOKEKA_SELF_TEST" = "1" ]; then
    run_self_test || exit 1
  else
    warn "self-test skipped (--no-self-test); run it later with: curl -fsSL https://hokeka.com/install-edge.sh | sudo bash -s -- --self-test --install-dir ${HOKEKA_INSTALL_DIR}"
  fi
}

# G5: --purge deletes the Edge Ledger (the PSP's multi-year system of record) and the node's
# identity, so it is confirmed first: --yes, or DELETE typed on the terminal. With neither (no
# terminal, e.g. an unattended run) nothing is deleted.
confirm_purge() {
  local answer=""
  if [ "$HOKEKA_ASSUME_YES" = "1" ]; then
    warn "--yes given: deleting the Edge Ledger, secrets and identity without asking"
    return 0
  fi
  if ! { : < "$HOKEKA_CONFIRM_TTY"; } 2>/dev/null; then
    die "--purge permanently deletes the Edge Ledger (every recorded evaluation — the PSP's system of record), the TLS/mTLS secrets and the node's enrolment identity under ${HOKEKA_INSTALL_DIR}.
       There is no terminal to confirm on, so nothing was deleted. Back up the ledger first, then
       re-run with --uninstall --purge --yes — or use --uninstall alone, which keeps all data."
  fi
  {
    printf '\n\033[0;31m[hokeka] --purge permanently deletes, under %s:\033[0m\n' "$HOKEKA_INSTALL_DIR"
    printf '  - the Edge Ledger (container volume ledger-data / data/): every recorded evaluation, the PSP'"'"'s system of record\n'
    printf '  - the Aerospike feature store, TLS + mTLS keystores and their passwords\n'
    printf '  - the enrolment identity: the node must be re-enrolled with a new install token\n'
    printf 'Back up the ledger first. Type DELETE to continue, anything else to cancel: '
  } >> "$HOKEKA_CONFIRM_TTY"
  IFS= read -r answer < "$HOKEKA_CONFIRM_TTY" || true
  [ "$answer" = "DELETE" ] || die "purge cancelled — nothing was deleted"
}

# Stop the Edge in whichever mode it runs, then remove the install. Without --purge only the
# replaceable program files go: the configuration, secrets (TLS keystores, ledger password),
# enrolment identity, ledger volume and bootstrap.env stay, so a later install or --upgrade resumes
# the same node. With --purge the stack is torn down with its volumes BEFORE its directories go —
# never deleting directories that running containers still have mounted.
do_uninstall() {
  require_root
  log "Uninstalling Hokeka Edge from ${HOKEKA_INSTALL_DIR}"
  local staging="${HOKEKA_INSTALL_DIR}/release-staging" compose
  # Ask before anything is stopped, so a cancelled purge leaves the Edge running and untouched.
  [ "$HOKEKA_PURGE" = "1" ] && confirm_purge
  # Container mode: compose services are restart: unless-stopped, so they must be brought down —
  # stopping a systemd unit (there is none in this mode) would leave them running.
  # The mode saved at install time decides; docker-compose.yml is staged in both modes, so its
  # presence alone is not proof of a container install. Without bootstrap.env (an install made by
  # install.sh directly), a staged .env written by the container path is the evidence.
  local saved_mode
  saved_mode="$(env_value "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env" HOKEKA_MODE)"
  if [ -s "$staging/docker-compose.yml" ] && { [ "$saved_mode" = "container" ]        || { [ -z "$saved_mode" ] && [ -s "$staging/.env" ]; }; }; then
    compose="$(compose_cmd)"
    [ -n "$compose" ] || die "the Edge was installed in container mode but no docker/podman compose is available to stop it — install it, or stop the hokeka containers by hand, then re-run"
    if [ "$HOKEKA_PURGE" = "1" ]; then
      ( cd "$staging" && $compose down --volumes --remove-orphans ) \
        || die "'${compose} down --volumes' failed in ${staging} — nothing was deleted"
      ok "Edge containers stopped and removed, with their volumes"
    else
      ( cd "$staging" && $compose down --remove-orphans ) \
        || die "'${compose} down' failed in ${staging} — nothing was deleted"
      ok "Edge containers stopped and removed (volumes kept)"
    fi
  fi
  # Native mode: the systemd unit written by install.sh.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop hokeka-edge 2>/dev/null || true
    systemctl disable hokeka-edge 2>/dev/null || true
    rm -f /etc/systemd/system/hokeka-edge.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  if [ "$HOKEKA_PURGE" = "1" ]; then
    local was_native=0
    [ "$(env_value "${HOKEKA_INSTALL_DIR}/etc/bootstrap.env" HOKEKA_MODE)" = "native" ] && was_native=1
    rm -rf "$HOKEKA_INSTALL_DIR"
    ok "Removed ${HOKEKA_INSTALL_DIR} (purged)"
    # Native mode keeps its ledger in the host's PostgreSQL 16, which other software may share;
    # the database is named so the operator can drop it deliberately.
    [ "$was_native" = "1" ] && warn "Native mode: the ledger database 'hokeka_ledger' (role 'hokeka_edge') is still in the host PostgreSQL. After a backup, drop it with: sudo -u postgres psql -c 'DROP DATABASE hokeka_ledger' -c 'DROP ROLE hokeka_edge'"
    return 0
  fi
  rm -rf "${HOKEKA_INSTALL_DIR:?}/bin" "${HOKEKA_INSTALL_DIR:?}/lib"
  rm -f "$staging/install.sh" "$staging/edge-host.jar" "$staging"/libedge_engine*.so
  ok "Removed the Edge program files"
  warn "Kept configuration, secrets, enrolment identity and ledger data under ${HOKEKA_INSTALL_DIR} (config/, secrets/, data/, etc/ and release-staging/{.env,config,secrets,data}) and the ledger volume — re-run with --uninstall --purge to delete them"
}

# Upgrade: re-fetch release and re-run install.sh offline without consuming a new token.
do_upgrade() {
  require_root
  apply_proxy_env
  detect_platform
  install_host_deps
  load_bootstrap_env
  # On upgrade the node is already enrolled: reuse the enrollment code saved at install time
  # (HOKEKA_ENROLL_CODE in bootstrap.env) or, when present, the one install.sh wrote into the
  # Edge's own environment file, so a still-PENDING node can activate. Never invent a placeholder
  # code — an ACTIVE node does not need one.
  local env_file existing_code
  env_file="$(edge_env_file "$HOKEKA_MODE")"
  if [ -s "$env_file" ]; then
    existing_code="$(grep -E '^EDGE_ENROLLMENT_CODE=' "$env_file" | head -1 | cut -d= -f2- || true)"
    [ -n "$existing_code" ] && REDEEM_ENROLL_CODE="$existing_code"
  fi
  # Target: --version when given, else the latest release (never the saved installed version).
  resolve_version
  preflight
  fetch_release
  run_inner_install
  ok "Upgrade to v${RESOLVED_VERSION} complete"
  finish_with_self_test
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
  log "Docs: https://docs.hokeka.com/docs/06-edge-public-install"
  finish_with_self_test
  log "Next: the node shows as Active on Console → Edge Nodes."
}

# Entrypoint: dispatch install / upgrade / uninstall.
main() {
  parse_args "$@"
  case "$HOKEKA_ACTION" in
    uninstall) do_uninstall ;;
    upgrade) do_upgrade ;;
    selftest) do_self_test ;;
    install) do_install ;;
    *) die "unknown action: $HOKEKA_ACTION" ;;
  esac
}

main "$@"
