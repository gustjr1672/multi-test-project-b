/// <summary>
/// 배포 메타정보(색상/이미지태그/깃 SHA/호스트/기동시각)를 환경변수에서 읽어 한 곳에 모은다.
/// docker-compose.yml 가 컨테이너별로 APP_COLOR/IMAGE_TAG/GIT_SHA 를 주입하고,
/// HOSTNAME 은 도커가 컨테이너 ID로 자동 설정한다.
/// 값이 없는 로컬 실행 등에서는 안전한 기본값으로 떨어진다.
/// </summary>
public static class DeploymentInfo
{
    // 이 프로세스(컨테이너)가 기동된 시각 — 배포 직후 교체됐는지 확인용
    public static readonly DateTimeOffset StartedAt = DateTimeOffset.UtcNow;

    // blue / green — docker-compose 의 서비스별 고정값
    public static string Color => Environment.GetEnvironmentVariable("APP_COLOR") ?? "unknown";

    // v1718... — deploy.sh 가 매 배포마다 새로 찍는 이미지 태그
    public static string ImageTag => Environment.GetEnvironmentVariable("IMAGE_TAG") ?? "local";

    // 짧은 git SHA — deploy.sh 가 git rev-parse 로 주입
    public static string GitSha => Environment.GetEnvironmentVariable("GIT_SHA") ?? "n/a";

    // 컨테이너 ID(도커가 HOSTNAME 으로 자동 설정). 로컬이면 머신명.
    public static string Host => Environment.GetEnvironmentVariable("HOSTNAME") ?? Environment.MachineName;

    // 매 배포/blue-green 전환마다 달라지는 식별자 — 프론트가 이 값 변화를 "스위칭"으로 감지한다.
    public static string DeployId => $"{Color}@{ImageTag}";

    public static int UptimeSeconds => (int)(DateTimeOffset.UtcNow - StartedAt).TotalSeconds;
}
