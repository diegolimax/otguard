#!/bin/sh
# ==========================================================================
#  OTGuard — instalador one-liner com SHA256 + GPG verify + barra de progresso
#
#  Modo "release"  (recomendado — mais robusto e nao precisa de jq):
#    curl -fsSL https://github.com/FeTads/otguard/releases/latest/download/install.sh | sudo sh
#
#  Modo "main branch"  (bootstrap — funciona se Actions ainda nao rodou):
#    curl -fsSL https://raw.githubusercontent.com/FeTads/otguard/main/install.sh | sudo sh
# ==========================================================================
set -e

GH_USER="FeTads"
GH_REPO="otguard"

# Estes dois sao substituidos pelo GitHub Actions ao gerar o install.sh
# que vai junto com cada release.  Se ainda forem os placeholders literais
# (ex: voce baixou direto do main), o instalador cai no modo API + .sha256.
VERSION="__VERSION__"
SHA256="__SHA256__"

# Fingerprint da chave GPG que assina TODAS as releases — gravado no install.sh
GPG_FINGERPRINT="C35758008A4DEB52EC996C785A7E6EADE40BB4A0"
GPG_KEY_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/otguard-public.gpg"

# ---- ui helpers ----------------------------------------------------------
if [ -t 1 ]; then T='\033[1;36m'; O='\033[1;32m'; E='\033[1;31m'; W='\033[1;33m'; D='\033[2m'; R='\033[0m'
else T=''; O=''; E=''; W=''; D=''; R=''; fi
say()  { printf '%b\n' "$*"; }
ok()   { printf '%b\n' "  ${O}✓${R} $*"; }
warn() { printf '%b\n' "  ${W}!${R} $*"; }
err()  { printf '%b\n' "  ${E}✗${R} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---- barra de progresso --------------------------------------------------
STAGES=8
STAGE=0
BAR_W=24

_rep() { _n=$1; _c=$2; _r=''; while [ "$_n" -gt 0 ]; do _r="$_r$_c"; _n=$((_n-1)); done; printf '%s' "$_r"; }

_draw() {
  _pct=$(( STAGE * 100 / STAGES ));   [ "$_pct" -gt 100 ] && _pct=100
  _fill=$(( STAGE * BAR_W / STAGES )); [ "$_fill" -gt "$BAR_W" ] && _fill=$BAR_W
  _empty=$(( BAR_W - _fill ))
  if [ -t 1 ]; then
    # bar com cor + mensagem (que pode conter codigos de cor — usa %b)
    printf '\r  [%b%s%b%s%b] %3d%%  ' \
      "$O" "$(_rep "$_fill" '=')" "$D" "$(_rep "$_empty" '.')" "$R" "$_pct"
    printf '%b\033[K' "$1"
  else
    # fallback sem tty
    printf '  [%s%s] %3d%%  %b\n' "$(_rep "$_fill" '=')" "$(_rep "$_empty" '.')" "$_pct" "$1"
  fi
}

# step "mensagem"  — etapa instantanea (mostra ✓ e quebra linha)
step() {
  STAGE=$((STAGE+1))
  _draw "$1 ${O}✓${R}"
  printf '\n'
}

# step_run "mensagem" cmd...  — etapa longa com spinner + timer ao vivo
step_run() {
  STAGE=$((STAGE+1))
  _msg=$1; shift
  _log=$(mktemp 2>/dev/null || echo "/tmp/otg-inst.$$")
  "$@" >"$_log" 2>&1 &
  _pid=$!
  _s=0
  [ -t 1 ] && printf '\033[?25l'   # esconde cursor
  while kill -0 "$_pid" 2>/dev/null; do
    case $((_s%4)) in 0) _c='|';; 1) _c='/';; 2) _c='-';; *) _c='\';; esac
    _elapsed=$(printf '%02d:%02d' $((_s/60)) $((_s%60)))
    _draw "$_msg  $_c $_elapsed"
    sleep 1; _s=$((_s+1))
  done
  wait "$_pid" 2>/dev/null; _rc=$?
  [ -t 1 ] && printf '\033[?25h'   # mostra cursor
  _elapsed=$(printf '%02d:%02d' $((_s/60)) $((_s%60)))
  if [ $_rc = 0 ]; then
    _draw "$_msg ${O}✓${R} $_elapsed"
    printf '\n'
  else
    _draw "$_msg ${E}✗ FALHOU${R} $_elapsed"
    printf '\n'
    err "saida do comando que falhou:"
    tail -n 20 "$_log" >&2
  fi
  rm -f "$_log"
  return $_rc
}

# --------------------------------------------------------------------------
say ""
say "  ${T}OTGuard${R}  ${D}—${R}  ${T}instalador automatico${R}"
say "  ${D}──────────────────────────────────────────────────────${R}"

[ "$(id -u)" = 0 ]                 || die "rode como root:  curl ... | sudo sh"
command -v apt-get >/dev/null 2>&1 || die "este instalador e para Debian/Ubuntu (apt)."
step "ambiente ok (Debian/Ubuntu + root)"

# ---- modo: release (substituido pelo Actions) ou bootstrap (main) --------
if [ "$VERSION" != "__VERSION__" ] && [ "$SHA256" != "__SHA256__" ]; then
  MODE=release
  deb_url="https://github.com/${GH_USER}/${GH_REPO}/releases/download/v${VERSION}/otguard_${VERSION}_all.deb"
  sha_url=""
  EXPECTED_SHA="$SHA256"
  needs="curl ca-certificates gnupg"
else
  MODE=bootstrap
  needs="curl ca-certificates gnupg jq"
fi

# ---- deps minimas pro instalador -----------------------------------------
step_run "instalando ferramentas auxiliares" \
  sh -c "DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $needs"

# ---- descobrir URLs no modo bootstrap ------------------------------------
if [ "$MODE" = bootstrap ]; then
  api=$(curl -fsSL "https://api.github.com/repos/${GH_USER}/${GH_REPO}/releases/latest" 2>/dev/null) \
    || die "falha ao falar com a API do GitHub (rede? rate-limit?)"
  deb_url=$(printf '%s' "$api" | jq -r '.assets[] | select(.name|endswith(".deb")) | .browser_download_url' | head -1)
  sha_url=$(printf '%s' "$api" | jq -r '.assets[] | select(.name|endswith(".deb.sha256")) | .browser_download_url' | head -1)
  [ -n "$deb_url" ] || die "nao encontrei .deb nas releases de ${GH_USER}/${GH_REPO}"
fi
step "release encontrada: $(basename "$deb_url")"

# ---- download ------------------------------------------------------------
tmp=$(mktemp -d) || die "mktemp falhou"
trap 'rm -rf "$tmp"' EXIT
deb="$tmp/otguard.deb"

step_run "baixando .deb da release" \
  curl -fsSL -o "$deb" "$deb_url"

# ---- verificacao GPG (camada criptografica forte) ------------------------
sig_url="${deb_url}.sig"
gpg_done=0
if curl -fsSL -o "$tmp/deb.sig" "$sig_url" 2>/dev/null && [ -s "$tmp/deb.sig" ]; then
  curl -fsSL -o "$tmp/pubkey.gpg" "$GPG_KEY_URL" 2>/dev/null && [ -s "$tmp/pubkey.gpg" ] \
    || die "falha ao baixar chave publica GPG ($GPG_KEY_URL)"
  GNUPGHOME=$(mktemp -d -p "$tmp" gnupg.XXXXXX); chmod 700 "$GNUPGHOME"; export GNUPGHOME
  gpg --batch --import "$tmp/pubkey.gpg" 2>/dev/null \
    || die "falha ao importar chave publica GPG"
  actual_fp=$(gpg --batch --list-keys --with-colons 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')
  if [ "$actual_fp" != "$GPG_FINGERPRINT" ]; then
    err "fingerprint GPG inesperado!"
    err "  esperado: $GPG_FINGERPRINT"
    err "  obtido:   $actual_fp"
    die "abortando — alguem trocou a chave publica no repo"
  fi
  gpg --batch --verify "$tmp/deb.sig" "$deb" 2>/dev/null \
    || die "ASSINATURA GPG INVALIDA — o .deb nao foi assinado por essa chave"
  unset GNUPGHOME
  gpg_done=1
fi
if [ "$gpg_done" = 1 ]; then
  step "GPG verificado (chave $(printf '%s' "$GPG_FINGERPRINT" | cut -c1-16)...)"
else
  STAGE=$((STAGE+1)); _draw "GPG ausente — usando so SHA256 ${W}!${R}"; printf '\n'
fi

# ---- verificacao do SHA256 ----------------------------------------------
if [ "$MODE" = bootstrap ] && [ -n "$sha_url" ]; then
  curl -fsSL -o "$tmp/sha" "$sha_url" 2>/dev/null && \
    EXPECTED_SHA=$(awk '{print $1}' "$tmp/sha" | head -1)
fi
if [ -n "${EXPECTED_SHA:-}" ]; then
  actual=$(sha256sum "$deb" | awk '{print $1}')
  if [ "$EXPECTED_SHA" = "$actual" ]; then
    step "SHA256 verificado ($(printf '%s' "$actual" | cut -c1-16)...)"
  else
    err "SHA256 NAO bate!"
    err "  esperado:  $EXPECTED_SHA"
    err "  obtido:    $actual"
    die "abortando — alguem mexeu no arquivo OU houve corrupcao na transferencia"
  fi
else
  STAGE=$((STAGE+1)); _draw "SHA256 indisponivel ${W}!${R}"; printf '\n'
fi

# ---- instala -------------------------------------------------------------
step_run "instalando via apt + rodando postinst" \
  sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y '$deb'"

step "instalacao concluida"

say ""
say "  ${O}✓ OTGuard instalado.${R}"
say ""
say "  ${T}Proximo passo:${R}  rode o wizard com:"
say ""
say "      ${O}sudo otguard${R}"
say ""
say "  ${D}Outros comandos:  sudo otguard help${R}"
say ""
