#!/bin/bash

# ==================================================
# 1. 현재 타겟 확인 (Project B 기준)
# ==================================================
IS_GREEN=$(docker ps -q -f name=api-green-b)

if [ -n "$IS_GREEN" ]; then
    CURRENT_TARGET="api-green-b"
    NEW_TARGET="api-blue-b"
    OLD_TARGET="api-green-b"
    NEW_PORT="9080"
else
    CURRENT_TARGET="api-blue-b"
    NEW_TARGET="api-green-b"
    OLD_TARGET="api-blue-b"
    NEW_PORT="9081"
fi

echo "CURRENT_TARGET=[$CURRENT_TARGET]"
echo "🚀 배포 시작: Project B 새로운 버전($NEW_TARGET) 준비"

export IMAGE_TAG="v$(date +%s)"

# ==================================================
# 2. 새로운 타겟 빌드 및 실행
# ==================================================
docker compose up -d --build $NEW_TARGET

# ==================================================
# 3. 헬스 체크 (호스트에서 직접 찌르기)
# ==================================================
echo "헬스 체크 진행 중 (가상머신 포트 $NEW_PORT 확인)"
for i in {1..10}
do
    STATUS_CODE=$(curl -o /dev/null -s -w "%{http_code}\n" http://127.0.0.1:$NEW_PORT/health)
    
    if [ "$STATUS_CODE" == "200" ]; then
        echo "✅ 헬스 체크 통과!"
        break
    fi
    echo "대기 중... ($i/10)"
    sleep 2
done

sleep 3

if [ "$STATUS_CODE" != "200" ]; then
    echo "🚨 헬스 체크 실패! 새 컨테이너를 내립니다."
    docker compose stop $NEW_TARGET
    exit 1
fi

# ==================================================
# 4. Master Nginx 스위칭 (동기화 지연 및 Inode 보존 완벽 처리)
# ==================================================
echo "🔄 트래픽을 $NEW_TARGET($NEW_PORT) 포트로 전환합니다."

# Master Nginx 설정 파일 경로
MASTER_CONF="/home/jhs/master-nginx/master-nginx.conf"

# ⭐️ Project B 전용 꼬리표(# project-b)를 타겟팅하여 포트 번호 교체
sed "s/server 127.0.0.1:[0-9]*; # project-b/server 127.0.0.1:$NEW_PORT; # project-b/g" $MASTER_CONF > master-nginx-b.tmp
cat master-nginx-b.tmp > $MASTER_CONF
rm master-nginx-b.tmp

# 수정한 설정 파일 내용을 Nginx 컨테이너 안으로 직접 쏴주기
#cat $MASTER_CONF | docker exec -i master-nginx sh -c 'cat > /etc/nginx/nginx.conf'

# 문법 검사 및 리로드
docker exec master-nginx nginx -t
docker exec master-nginx nginx -s reload

echo "Nginx 교대 대기 중... (2초)"
sleep 2

# ==================================================
# 5. 구버전 종료
# ==================================================
echo "🛑 기존 버전($OLD_TARGET) 종료를 요청합니다."
docker compose stop $OLD_TARGET &
STOP_PID=$!
ELAPSED=0

while kill -0 $STOP_PID 2>/dev/null; do
    echo -ne "\r⏳ 처리 중인 남은 요청 대기 중... ${ELAPSED}초 경과\t"
    sleep 1
    ((ELAPSED++))
done

echo -e "\n✅ $OLD_TARGET 종료 완료! (총 ${ELAPSED}초 소요)"

echo "IMAGE_TAG=${IMAGE_TAG}" > .env
echo "LAST_TARGET=${NEW_TARGET}" >> .env
echo "🎉 Project B 무중단 배포 완료!"