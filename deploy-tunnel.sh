#!/usr/bin/env bash
# ============================================================
#  게임 서버 + Cloudflare Tunnel 배포 (NAVER Cloud / Rocky Linux 8.x)
#
#  ACG(방화벽) 인바운드 포트를 하나도 열지 않습니다.
#  서버가 바깥으로만 연결하므로 22번 외에 아무것도 개방하지 않아도
#  공개 HTTPS 주소로 게임을 서비스할 수 있습니다.
#
#  사용법:
#    sudo bash deploy-tunnel.sh
#        → 무료 임시 주소(*.trycloudflare.com) 발급. 계정 불필요.
#
#    sudo TUNNEL_TOKEN='eyJhIjoi...' bash deploy-tunnel.sh
#        → Cloudflare 계정의 고정 도메인에 연결(주소가 변하지 않음).
#
#  이후 명령:
#    sudo tunnel-url      현재 공개 주소 확인
#    sudo update-games    게임 최신본 갱신
# ============================================================
set -euo pipefail

WEBROOT="/var/www/games"
NGINX_PORT="${NGINX_PORT:-8080}"        # 로컬 전용(외부 노출 없음)
CONF="/etc/nginx/conf.d/games.conf"
CFBIN="/usr/local/bin/cloudflared"
CFLOG="/var/log/cloudflared-games.log"
STATE="/var/lib/games-tunnel"
UNIT="/etc/systemd/system/games-tunnel.service"
JUMPROPE_URL="https://raw.githubusercontent.com/wooing1/jumprope/main/index.html"
TUNNEL_TOKEN="${TUNNEL_TOKEN:-}"

say(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok(){  printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }
die(){ printf '\n\033[1;31m✘ %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" -eq 0 ] || die "root로 실행해주세요:  sudo bash $0"

# ------------------------------------------------------------
say "1/8  필수 패키지"
command -v curl >/dev/null 2>&1 || dnf install -y curl >/dev/null
if ! command -v nginx >/dev/null 2>&1; then
  dnf install -y nginx >/dev/null && ok "nginx 설치"
else
  ok "nginx 이미 설치됨"
fi

# ------------------------------------------------------------
say "2/8  게임 파일 배치"
mkdir -p "$WEBROOT"/jumprope "$WEBROOT"/plane "$STATE"
if curl -fsSL --retry 3 --connect-timeout 15 "$JUMPROPE_URL" -o "$WEBROOT/jumprope/index.html.tmp"; then
  if [ -s "$WEBROOT/jumprope/index.html.tmp" ] && grep -q "탭탭 줄넘기" "$WEBROOT/jumprope/index.html.tmp"; then
    mv -f "$WEBROOT/jumprope/index.html.tmp" "$WEBROOT/jumprope/index.html"
    ok "탭탭 줄넘기 ($(wc -c < "$WEBROOT/jumprope/index.html") bytes)"
  else
    rm -f "$WEBROOT/jumprope/index.html.tmp"; warn "내려받은 파일이 올바르지 않음 — 기존 유지"
  fi
else
  rm -f "$WEBROOT/jumprope/index.html.tmp"
  [ -f "$WEBROOT/jumprope/index.html" ] || die "게임을 내려받지 못했고 기존 파일도 없습니다. 서버의 외부 인터넷 연결을 확인해주세요."
  warn "갱신 실패 — 기존 파일 유지"
fi

if [ ! -f "$WEBROOT/plane/index.html" ]; then
cat > "$WEBROOT/plane/index.html" <<'PLANE_EOF'
<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>비행기 게임 · 준비 중</title>
<style>
 html,body{margin:0;height:100%;font-family:'Trebuchet MS',system-ui,sans-serif;
   background:linear-gradient(#bfeaff,#e8faff);display:flex;align-items:center;justify-content:center;color:#2b2b3a}
 .card{background:rgba(255,255,255,.9);padding:34px 28px;border-radius:26px;text-align:center;
   box-shadow:0 10px 30px rgba(0,0,0,.15);max-width:360px}
 h1{margin:0 0 8px;font-size:28px;color:#ff5c8a}
 p{margin:0 0 18px;color:#5f5f74;font-size:14px;line-height:1.6}
 a{display:inline-block;text-decoration:none;font-weight:700;color:#fff;
   background:linear-gradient(#ff9bbb,#ff5c8a);padding:12px 20px;border-radius:16px;box-shadow:0 5px 0 #d94574}
</style></head><body>
<div class="card"><h1>✈️ 준비 중</h1>
<p>비행기 게임은 아직 준비 중이에요.<br>곧 이 자리에 올라옵니다!</p>
<a href="/">← 게임 목록으로</a></div></body></html>
PLANE_EOF
ok "비행기 게임 자리 준비 (/plane/)"
fi

cat > "$WEBROOT/index.html" <<'PORTAL_EOF'
<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,viewport-fit=cover">
<title>게임 모음</title>
<style>
 html,body{margin:0;min-height:100%;font-family:'Trebuchet MS','Segoe UI',system-ui,sans-serif;color:#2b2b3a;
   background:linear-gradient(#bfeaff,#e8faff);}
 .wrap{max-width:460px;margin:0 auto;padding:34px 20px 40px;}
 h1{font-size:32px;margin:0 0 4px;color:#ff5c8a;text-shadow:0 2px 0 #fff;text-align:center}
 .sub{text-align:center;color:#5f5f74;font-size:14px;margin:0 0 22px}
 a.card{display:flex;align-items:center;gap:14px;text-decoration:none;color:inherit;
   background:rgba(255,255,255,.9);border-radius:22px;padding:16px 18px;margin-bottom:14px;
   box-shadow:0 8px 20px rgba(0,0,0,.12);transition:transform .08s, box-shadow .08s}
 a.card:active{transform:translateY(3px);box-shadow:0 4px 12px rgba(0,0,0,.12)}
 .emoji{font-size:34px;line-height:1;flex:0 0 auto}
 .t{font-size:18px;font-weight:800;margin:0 0 3px}
 .d{font-size:13px;color:#5f5f74;margin:0;line-height:1.5}
 .tag{display:inline-block;font-size:11px;font-weight:700;padding:2px 8px;border-radius:999px;
   background:#ffe3ec;color:#ff5c8a;margin-left:6px;vertical-align:middle}
 .tag.soon{background:#eceff5;color:#6a6a80}
 .foot{text-align:center;color:#5f5f74;font-size:12px;margin-top:18px;line-height:1.6}
</style></head><body>
<div class="wrap">
  <h1>🎮 게임 모음</h1>
  <p class="sub">친구들과 같이 해보세요</p>
  <a class="card" href="/jumprope/">
    <div class="emoji">🐶</div>
    <div><p class="t">탭탭 줄넘기<span class="tag">1~4인</span></p>
    <p class="d">줄이 발밑에 올 때 딱 맞춰 점프! 방을 만들어 친구와 함께.</p></div>
  </a>
  <a class="card" href="/plane/">
    <div class="emoji">✈️</div>
    <div><p class="t">비행기 게임<span class="tag soon">준비 중</span></p>
    <p class="d">곧 공개됩니다.</p></div>
  </a>
  <p class="foot">모바일·PC 모두 지원 · 설치 없이 브라우저에서 바로 플레이</p>
</div></body></html>
PORTAL_EOF
ok "포털 생성"

# ------------------------------------------------------------
say "3/8  nginx 설정 (127.0.0.1:${NGINX_PORT} — 외부 노출 없음)"
cat > "$CONF" <<CONF_EOF
# 게임 서버 (자동 생성 — deploy-tunnel.sh)
# 로컬에만 바인딩한다. 외부 공개는 Cloudflare Tunnel이 담당하므로
# ACG/방화벽에 어떤 포트도 열 필요가 없다.
server {
    listen       127.0.0.1:${NGINX_PORT};
    server_name  _;
    root         $WEBROOT;
    index        index.html;

    gzip on;
    gzip_types text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    location ~* \\.html\$ { add_header Cache-Control "no-cache, must-revalidate"; }
    location ~* \\.(css|js|png|jpg|jpeg|gif|svg|ico|woff2?)\$ { expires 7d; add_header Cache-Control "public"; }
    location / { try_files \$uri \$uri/ =404; }
}
CONF_EOF
ok "$CONF"

chown -R root:root "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  command -v semanage >/dev/null 2>&1 || dnf install -y policycoreutils-python-utils >/dev/null 2>&1 || true
  semanage fcontext -a -t httpd_sys_content_t "${WEBROOT}(/.*)?" 2>/dev/null || true
  restorecon -R "$WEBROOT" >/dev/null 2>&1 || true
  semanage port -a -t http_port_t -p tcp "$NGINX_PORT" 2>/dev/null \
    || semanage port -m -t http_port_t -p tcp "$NGINX_PORT" 2>/dev/null || true
  ok "SELinux 적용 ($(getenforce))"
fi

nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx 설정 오류"; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
sleep 1
CODE=$(curl -s -o /tmp/_gt -w '%{http_code}' "http://127.0.0.1:${NGINX_PORT}/jumprope/" || echo 000)
if [ "$CODE" = "200" ] && grep -q "탭탭 줄넘기" /tmp/_gt; then
  ok "로컬 서비스 정상 (HTTP $CODE)"
else
  warn "기본 서버 블록 간섭 가능 — 보정 시도 (HTTP $CODE)"
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.games 2>/dev/null || true
  sed -i "s|root         /usr/share/nginx/html;|root         $WEBROOT;|" /etc/nginx/nginx.conf || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx && sleep 1
  CODE=$(curl -s -o /tmp/_gt -w '%{http_code}' "http://127.0.0.1:${NGINX_PORT}/jumprope/" || echo 000)
  [ "$CODE" = "200" ] && ok "보정 후 정상" || die "로컬 서비스 실패(HTTP $CODE). 'nginx -T | head -40' 확인 필요"
fi
rm -f /tmp/_gt

# ------------------------------------------------------------
say "4/8  cloudflared 설치"
if command -v cloudflared >/dev/null 2>&1; then
  CFBIN="$(command -v cloudflared)"; ok "이미 설치됨 ($($CFBIN --version 2>&1 | head -1))"
else
  case "$(uname -m)" in
    x86_64|amd64) CFARCH="amd64" ;;
    aarch64|arm64) CFARCH="arm64" ;;
    *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
  esac
  BASE="https://github.com/cloudflare/cloudflared/releases/latest/download"
  if curl -fsSL --retry 3 --connect-timeout 20 "$BASE/cloudflared-linux-${CFARCH}.rpm" -o /tmp/cf.rpm 2>/dev/null \
     && dnf install -y /tmp/cf.rpm >/dev/null 2>&1; then
    CFBIN="$(command -v cloudflared)"; ok "RPM으로 설치 ($($CFBIN --version 2>&1 | head -1))"
  elif curl -fsSL --retry 3 --connect-timeout 20 "$BASE/cloudflared-linux-${CFARCH}" -o "$CFBIN"; then
    chmod +x "$CFBIN"; ok "바이너리로 설치 ($($CFBIN --version 2>&1 | head -1))"
  else
    die "cloudflared를 내려받지 못했습니다. 서버의 외부 인터넷(HTTPS) 연결을 확인해주세요."
  fi
  rm -f /tmp/cf.rpm
fi

# ------------------------------------------------------------
if [ -n "$TUNNEL_TOKEN" ]; then
  say "5/8  고정 도메인 터널 등록 (Cloudflare 계정)"
  systemctl stop games-tunnel 2>/dev/null || true
  systemctl disable games-tunnel 2>/dev/null || true
  rm -f "$UNIT"; systemctl daemon-reload
  "$CFBIN" service uninstall >/dev/null 2>&1 || true
  "$CFBIN" service install "$TUNNEL_TOKEN" || die "터널 토큰 등록 실패 — 토큰을 다시 확인해주세요"
  systemctl enable --now cloudflared >/dev/null 2>&1 || true
  sleep 4
  systemctl is-active --quiet cloudflared && ok "cloudflared 서비스 실행 중" || warn "서비스 상태 확인: systemctl status cloudflared"
  echo "named" > "$STATE/mode"
  MODE="named"
else
  say "5/8  임시 터널 서비스 등록 (계정 불필요)"
  : > "$CFLOG"; chmod 640 "$CFLOG"
  cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Cloudflare Quick Tunnel for game server
After=network-online.target nginx.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=/bin/sh -c ': > ${CFLOG}'
ExecStart=${CFBIN} tunnel --no-autoupdate --url http://127.0.0.1:${NGINX_PORT} --logfile ${CFLOG}
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  systemctl enable games-tunnel >/dev/null 2>&1
  systemctl restart games-tunnel
  echo "quick" > "$STATE/mode"
  MODE="quick"
  ok "games-tunnel 서비스 등록"
fi

# ------------------------------------------------------------
say "6/8  공개 주소 확인"
PUBURL=""
if [ "$MODE" = "quick" ]; then
  for i in $(seq 1 24); do    # 최대 ~72초 대기
    PUBURL=$(grep -ohE 'https://[a-z0-9-]+\.trycloudflare\.com' "$CFLOG" 2>/dev/null | head -1 || true)
    [ -n "$PUBURL" ] && break
    if journalctl -u games-tunnel --no-pager -n 200 2>/dev/null \
        | grep -qE 'Host not in allowlist|failed to (dial|unmarshal)|context deadline'; then
      warn "터널 연결에 문제가 있는 것 같습니다"
      break
    fi
    sleep 3
  done
  if [ -n "$PUBURL" ]; then
    echo "$PUBURL" > "$STATE/url"
    ok "발급된 주소: $PUBURL"
  else
    warn "주소를 아직 못 받았습니다. 잠시 후 'sudo tunnel-url' 로 다시 확인해주세요."
    echo "     로그: journalctl -u games-tunnel -n 40 --no-pager"
    echo "           tail -20 $CFLOG"
  fi
else
  ok "Cloudflare 대시보드에 설정한 도메인으로 접속됩니다"
fi

# ------------------------------------------------------------
say "7/8  관리 명령 설치"
cat > /usr/local/bin/tunnel-url <<TU_EOF
#!/usr/bin/env bash
# 현재 공개 주소 확인
STATE="$STATE"; CFLOG="$CFLOG"
MODE=\$(cat "\$STATE/mode" 2>/dev/null || echo quick)
if [ "\$MODE" = "named" ]; then
  echo "고정 도메인 모드입니다. Cloudflare 대시보드의 Tunnels에서 설정한 주소를 사용하세요."
  systemctl is-active --quiet cloudflared 2>/dev/null && echo "상태: 실행 중" || echo "상태: 중지됨 (systemctl status cloudflared)"
  exit 0
fi
U=\$(grep -ohE 'https://[a-z0-9-]+\.trycloudflare\.com' "\$CFLOG" 2>/dev/null | head -1)
[ -z "\$U" ] && U=\$(cat "\$STATE/url" 2>/dev/null || true)
if [ -n "\$U" ]; then
  echo "\$U" > "\$STATE/url"
  echo "포털   : \$U/"
  echo "줄넘기 : \$U/jumprope/"
  echo "비행기 : \$U/plane/"
  systemctl is-active --quiet games-tunnel 2>/dev/null && echo "상태   : 실행 중" || echo "상태   : 중지됨"
else
  echo "아직 주소가 없습니다."
  echo "  systemctl status games-tunnel --no-pager | tail -20"
  echo "  tail -20 \$CFLOG"
  exit 1
fi
TU_EOF
chmod +x /usr/local/bin/tunnel-url
ok "sudo tunnel-url"

cat > /usr/local/bin/update-games <<'UPD_EOF'
#!/usr/bin/env bash
# 게임 최신본 다시 내려받기:  sudo update-games
set -euo pipefail
WEBROOT="/var/www/games"
declare -A GAMES=(
  [jumprope]="https://raw.githubusercontent.com/wooing1/jumprope/main/index.html"
)
for g in "${!GAMES[@]}"; do
  url="${GAMES[$g]}"
  mkdir -p "$WEBROOT/$g"
  if curl -fsSL --retry 3 "$url" -o "$WEBROOT/$g/index.html.tmp" && [ -s "$WEBROOT/$g/index.html.tmp" ]; then
    mv -f "$WEBROOT/$g/index.html.tmp" "$WEBROOT/$g/index.html"
    chmod 644 "$WEBROOT/$g/index.html"
    echo "✔ $g 갱신 완료"
  else
    rm -f "$WEBROOT/$g/index.html.tmp"; echo "✘ $g 갱신 실패"
  fi
done
command -v restorecon >/dev/null 2>&1 && restorecon -R "$WEBROOT" >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || true
echo "완료. (터널 주소는 그대로입니다)"
UPD_EOF
chmod +x /usr/local/bin/update-games
ok "sudo update-games"

# ------------------------------------------------------------
say "8/8  외부 접속 자체 점검"
if [ -n "$PUBURL" ]; then
  sleep 5
  for i in 1 2 3 4 5 6; do
    OUT=$(curl -s -m 25 -o /tmp/_pt -w '%{http_code}' "$PUBURL/jumprope/" 2>/dev/null || echo 000)
    if [ "$OUT" = "200" ] && grep -q "탭탭 줄넘기" /tmp/_pt 2>/dev/null; then
      ok "공개 주소로 게임 응답 정상 (HTTP $OUT)"; break
    fi
    [ $i -eq 6 ] && warn "공개 주소 응답 확인 실패(HTTP $OUT) — 전파에 1~2분 걸릴 수 있습니다"
    sleep 8
  done
  rm -f /tmp/_pt
else
  warn "공개 주소가 없어 외부 점검을 건너뜁니다"
fi

cat <<DONE

============================================================
 배포 완료 🎉   (ACG 인바운드 포트 개방 0개)
DONE
if [ "$MODE" = "quick" ] && [ -n "$PUBURL" ]; then
cat <<DONE2

   포털        ${PUBURL}/
   줄넘기      ${PUBURL}/jumprope/
   비행기      ${PUBURL}/plane/   (준비 중)

 ⚠ 임시 주소 특성
   · 터널이 재시작되면 주소가 바뀝니다 → sudo tunnel-url 로 확인
   · 주소를 아는 사람은 누구나 접속 가능한 공개 URL입니다
   · 주소를 고정하고 싶으면 (무료 Cloudflare 계정 필요):
       1) dash.cloudflare.com → Zero Trust → Networks → Tunnels → Create
       2) 발급된 토큰으로:
          sudo TUNNEL_TOKEN='eyJhIjoi...' bash deploy-tunnel.sh
DONE2
elif [ "$MODE" = "named" ]; then
cat <<DONE3

   Cloudflare 대시보드에서 설정한 도메인으로 접속됩니다.
   Public Hostname 의 Service 를  http://127.0.0.1:${NGINX_PORT}  로 지정하세요.
DONE3
fi
cat <<DONE4

 관리 명령
   sudo tunnel-url      현재 공개 주소 확인
   sudo update-games    게임 최신본 갱신
   systemctl status games-tunnel     터널 상태
   journalctl -u games-tunnel -n 40  터널 로그

 SSH는 그대로 22번을 사용합니다(변경 없음).
============================================================
DONE4
