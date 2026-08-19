#!/usr/bin/env bash
# ============================================================
#  게임 서버 배포 스크립트 (NAVER Cloud / Rocky Linux 8.x)
#  서버에서 root로 한 번 실행하면 nginx + 게임 포털이 세팅됩니다.
#
#  사용법:  sudo bash deploy-games.sh
#  나중에 갱신:  sudo update-games
# ============================================================
set -euo pipefail

WEBROOT="/var/www/games"
CONF="/etc/nginx/conf.d/games.conf"
JUMPROPE_URL="https://raw.githubusercontent.com/wooing1/jumprope/main/index.html"

say(){ printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
ok(){  printf '  \033[1;32m✔\033[0m %s\n' "$*"; }
warn(){ printf '  \033[1;33m!\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "root로 실행해주세요:  sudo bash $0"; exit 1; }

# ------------------------------------------------------------
say "1/7  nginx 설치"
if ! command -v nginx >/dev/null 2>&1; then
  dnf install -y nginx >/dev/null
  ok "nginx 설치 완료"
else
  ok "nginx 이미 설치됨 ($(nginx -v 2>&1 | sed 's|nginx version: ||'))"
fi
command -v curl >/dev/null 2>&1 || dnf install -y curl >/dev/null

# ------------------------------------------------------------
say "2/7  디렉터리 구성"
mkdir -p "$WEBROOT"/jumprope "$WEBROOT"/plane
ok "$WEBROOT/{jumprope,plane}"

# ------------------------------------------------------------
say "3/7  게임 파일 내려받기"
if curl -fsSL --retry 3 --connect-timeout 15 "$JUMPROPE_URL" -o "$WEBROOT/jumprope/index.html.tmp"; then
  # 정상 HTML인지 최소 검증 후 교체(빈 파일/오류 페이지 방어)
  if [ -s "$WEBROOT/jumprope/index.html.tmp" ] && grep -q "탭탭 줄넘기" "$WEBROOT/jumprope/index.html.tmp"; then
    mv -f "$WEBROOT/jumprope/index.html.tmp" "$WEBROOT/jumprope/index.html"
    ok "탭탭 줄넘기 배포 ($(wc -c < "$WEBROOT/jumprope/index.html") bytes)"
  else
    rm -f "$WEBROOT/jumprope/index.html.tmp"
    warn "내려받은 파일이 올바르지 않습니다. 기존 파일을 유지합니다."
  fi
else
  rm -f "$WEBROOT/jumprope/index.html.tmp"
  warn "GitHub에서 내려받기 실패(서버 외부 인터넷 연결 확인). 기존 파일 유지."
fi

# 비행기 게임 자리(나중에 파일만 올리면 바로 서비스)
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
else
ok "비행기 게임 파일 이미 있음 — 그대로 유지"
fi

# ------------------------------------------------------------
say "4/7  포털(게임 목록) 페이지 생성"
cat > "$WEBROOT/index.html" <<'PORTAL_EOF'
<!DOCTYPE html><html lang="ko"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,viewport-fit=cover">
<title>게임 모음</title>
<style>
 :root{--ink:#2b2b3a}
 html,body{margin:0;min-height:100%;font-family:'Trebuchet MS','Segoe UI',system-ui,sans-serif;color:var(--ink);
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
say "5/7  nginx 설정"
cat > "$CONF" <<CONF_EOF
# 게임 서버 (자동 생성 — deploy-games.sh)
server {
    listen       80;
    listen       [::]:80;
    server_name  _;
    root         $WEBROOT;
    index        index.html;

    gzip on;
    gzip_types text/html text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;

    # HTML은 항상 최신을 받도록(게임 업데이트가 바로 반영됨)
    location ~* \\.html\$ {
        add_header Cache-Control "no-cache, must-revalidate";
    }
    # 정적 리소스는 캐시
    location ~* \\.(css|js|png|jpg|jpeg|gif|svg|ico|woff2?)\$ {
        expires 7d;
        add_header Cache-Control "public";
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
CONF_EOF
ok "$CONF"

# 권한 / SELinux
chown -R root:root "$WEBROOT"
find "$WEBROOT" -type d -exec chmod 755 {} \;
find "$WEBROOT" -type f -exec chmod 644 {} \;
if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" != "Disabled" ]; then
  command -v semanage >/dev/null 2>&1 || dnf install -y policycoreutils-python-utils >/dev/null 2>&1 || true
  semanage fcontext -a -t httpd_sys_content_t "${WEBROOT}(/.*)?" 2>/dev/null || true
  restorecon -R "$WEBROOT" >/dev/null 2>&1 || true
  ok "SELinux 컨텍스트 적용 ($(getenforce))"
fi

nginx -t >/dev/null 2>&1 || { echo "nginx 설정 오류:"; nginx -t; exit 1; }
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx
ok "nginx 실행 중"

# ------------------------------------------------------------
say "6/7  방화벽 개방 (80 / 443)"
if systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-service=http  >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-service=https >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  ok "firewalld: http/https 허용"
else
  warn "firewalld 미실행 — OS 방화벽은 건너뜁니다"
fi

# ------------------------------------------------------------
say "7/7  자체 점검"
CODE=$(curl -s -o /tmp/_gtest -w '%{http_code}' http://127.0.0.1/jumprope/ || echo 000)
if [ "$CODE" = "200" ] && grep -q "탭탭 줄넘기" /tmp/_gtest; then
  ok "게임 응답 정상 (HTTP $CODE)"
else
  warn "기본 서버 블록이 우선했을 수 있어 보정합니다 (HTTP $CODE)"
  # 스톡 기본 서버의 root를 게임 경로로 교체
  cp -n /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.games 2>/dev/null || true
  sed -i "s|root         /usr/share/nginx/html;|root         $WEBROOT;|" /etc/nginx/nginx.conf || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx
  CODE=$(curl -s -o /tmp/_gtest -w '%{http_code}' http://127.0.0.1/jumprope/ || echo 000)
  if [ "$CODE" = "200" ] && grep -q "탭탭 줄넘기" /tmp/_gtest; then ok "보정 후 정상 (HTTP $CODE)"
  else warn "여전히 비정상(HTTP $CODE) — 'nginx -T | head -60' 결과를 확인해주세요"; fi
fi
rm -f /tmp/_gtest

# 업데이트 도우미 설치
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
echo "완료."
UPD_EOF
chmod +x /usr/local/bin/update-games
ok "업데이트 명령 설치:  sudo update-games"

IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "서버IP")
cat <<DONE

============================================================
 배포 완료 🎉

   포털        http://$IP/
   줄넘기      http://$IP/jumprope/
   비행기      http://$IP/plane/   (준비 중)

 ⚠ 외부에서 접속이 안 되면 NAVER Cloud 콘솔에서
   ACG(방화벽) 인바운드 TCP 80 을 허용해야 합니다.
   (현재 22번만 열려 있는 상태였습니다)

 게임 최신본 갱신:   sudo update-games
============================================================
DONE
