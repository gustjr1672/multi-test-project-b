#!/bin/bash
# ==================================================
# Project B 무중단 배포 (개선판)
# 기존 deploy.sh 대비 변경점:
#  - set -euo pipefail 로 중간 단계 실패 시 즉시 중단 (구버전 무단 종료 방지)
#  - master-nginx.conf 경로를 환경변수(MASTER_CONF)로 분리 (하드코딩 제거)
#  - sed 치환이 실제로 적용됐는지 검증
#  - nginx -t / reload 성공을 확인한 뒤에만 구버전 종료
#  - 배포 후 오래된 이미지 정리(디스크 누적 방지)
#  - 불필요한 sleep / 백그라운드 폴링 / 죽은 코드 제거
# ==================================================
set -euo pipefail

# --------------------------------------------------
# 0. 설정 (운영 서버별로 다를 수 있는 값은 환경변수로)
# --------------------------------------------------
MASTER_CONF="${MASTER_CONF:-/home/jhs/master-nginx/master-nginx.conf}"
NGINX_CONTAINER="${NGINX_CONTAINER:-master-nginx}"
HEALTH_RETRIES="${HEALTH_RETRIES:-20}"   # 콜드스타트/DB 워밍업 여유로 기존(10회)보다 늘림
HEALTH_INTERVAL="${HEALTH_INTERVAL:-2}"

if [ ! -f "$MASTER_CONF" ]; then
    echo "🚨 master-nginx 설정 파일을 찾을 수 없습니다: $MASTER_CONF"
    exit 1
fi

# --------------------------------------------------
# 1. 현재 타겟 확인 (Project B 기준)
# --------------------------------------------------
IS_GREEN=$(docker ps -q -f name=api-green-b)

if [ -n "$IS_GREEN" ]; then
    CURRENT_TARGET="api-green-b"
    NEW_TARGET="api-blue-b"
    NEW_PORT="9080"
else
    CURRENT_TARGET="api-blue-b"
    NEW_TARGET="api-green-b"
    NEW_PORT="9081"
fi

echo "현재 버전=[$CURRENT_TARGET]"
echo "🚀 배포 시작: Project B 새로운 버전($NEW_TARGET) 준비"

export IMAGE_TAG="v$(date +%s)"
# 짧은 git SHA 를 컨테이너 env(GIT_SHA)로 주입 → 앱이 /health·API 응답에 실어 화면에서 추적
export GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"

# --------------------------------------------------
# 1-1. DB 접속정보를 secret 파일로 기록 (docker inspect 평문 노출 방지)
#  - $DB_URL 은 GitHub Secret 에서 워크플로 env 로 주입됨
#  - docker-compose.yml 의 secrets.db_url.file(./secrets/db_url)이 이 파일을 가리킨다.
#    이 파일이 없으면 'multi-test-project-b_db_url does not exist' 로 compose 가 실패함.
#  - 환경변수 대신 파일로 넘겨 컨테이너 내부 tmpfs(/run/secrets)에만 존재하게 함
# --------------------------------------------------
SECRET_DIR="./secrets"
mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"
# 줄바꿈 없이 값만 기록 (printf). DB_URL 미설정(로컬 등)이어도 set -u 에 걸리지 않게 ${DB_URL:-}.
printf '%s' "${DB_URL:-}" > "$SECRET_DIR/db_url"
chmod 600 "$SECRET_DIR/db_url"
if [ ! -s "$SECRET_DIR/db_url" ]; then
    echo "⚠️  경고: DB_URL 이 비어 있어 secrets/db_url 이 빈 파일입니다. (CI 라면 secrets.DB_URL 주입 여부 확인)"
fi

# --------------------------------------------------
# 2. 새로운 타겟 빌드 및 실행
#    (set -e 로 빌드 실패 시 여기서 즉시 중단)
# --------------------------------------------------
docker compose up -d --build "$NEW_TARGET"

# --------------------------------------------------
# 3. 헬스 체크 (호스트에서 직접 찌르기)
#    주의: /health 는 현재 DB 연결을 검증하지 않으므로,
#    운영 안전성을 위해 Program.cs 에 DB readiness 체크 추가 권장.
# --------------------------------------------------
echo "헬스 체크 진행 중 (포트 $NEW_PORT 확인)"
STATUS_CODE=""
for i in $(seq 1 "$HEALTH_RETRIES")
do
    STATUS_CODE=$(curl -o /dev/null -s -w "%{http_code}" "http://127.0.0.1:$NEW_PORT/health" || true)

    if [ "$STATUS_CODE" == "200" ]; then
        echo "✅ 헬스 체크 통과!"
        break
    fi
    echo "대기 중... ($i/$HEALTH_RETRIES) 응답코드=$STATUS_CODE"
    sleep "$HEALTH_INTERVAL"
done

if [ "$STATUS_CODE" != "200" ]; then
    echo "🚨 헬스 체크 실패! 새 컨테이너를 내립니다. (구버전은 그대로 유지)"
    docker compose stop "$NEW_TARGET"
    exit 1
fi

# --------------------------------------------------
# 4. Master Nginx 스위칭
#    - sed 로 # project-b 마커가 붙은 upstream 포트만 교체
#    - cat tmp > 원본 방식으로 inode 보존 (bind-mount 연결 유지 목적)
# --------------------------------------------------
echo "🔄 트래픽을 $NEW_TARGET($NEW_PORT) 포트로 전환합니다."

TMP_CONF="$(mktemp)"
sed "s/server 127.0.0.1:[0-9]*; # project-b/server 127.0.0.1:$NEW_PORT; # project-b/g" \
    "$MASTER_CONF" > "$TMP_CONF"

# ⭐ 치환이 실제로 적용됐는지 검증 (마커 형식이 틀어지면 조용히 실패하는 사고 방지)
if ! grep -q "server 127.0.0.1:$NEW_PORT; # project-b" "$TMP_CONF"; then
    echo "🚨 nginx 설정에서 '# project-b' upstream 라인을 찾지 못했습니다. 전환 중단."
    rm -f "$TMP_CONF"
    docker compose stop "$NEW_TARGET"
    exit 1
fi

# inode 보존하며 원본 갱신
cat "$TMP_CONF" > "$MASTER_CONF"
rm -f "$TMP_CONF"

# ⭐ 문법 검사 → 통과해야만 reload (실패 시 구버전 그대로, 다운타임 없음)
if ! docker exec "$NGINX_CONTAINER" nginx -t; then
    echo "🚨 nginx 설정 문법 오류! reload/구버전 종료를 중단합니다."
    docker compose stop "$NEW_TARGET"
    exit 1
fi

docker exec "$NGINX_CONTAINER" nginx -s reload

echo "Nginx 교대 대기 중... (2초)"
sleep 2

# --------------------------------------------------
# 5. 구버전 종료 (전환이 모두 성공한 뒤에만 도달)
#    docker compose stop 은 완료까지 블로킹되므로 그대로 호출.
#    in-flight 요청은 stop_grace_period(60s) 동안 드레인됨.
# --------------------------------------------------
echo "🛑 기존 버전($CURRENT_TARGET) 종료 요청 (요청 드레인 대기)..."
docker compose stop "$CURRENT_TARGET"
echo "✅ $CURRENT_TARGET 종료 완료!"

# --------------------------------------------------
# 6. 정리: 오래된 dangling 이미지 제거 (디스크 누적 방지)
# --------------------------------------------------
docker image prune -f >/dev/null 2>&1 || true

echo "🎉 Project B 무중단 배포 완료! (live=$NEW_TARGET:$NEW_PORT, image=$IMAGE_TAG)"
