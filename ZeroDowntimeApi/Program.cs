using Data.Application;

var builder = WebApplication.CreateBuilder(args);

// DB 접속정보를 secret 파일(/run/secrets/db_url)에서 읽어 주입.
// 환경변수로 직접 넣으면 docker inspect 로 평문 노출되므로 파일 기반 secret 사용.
// 파일이 없으면(로컬 등) 기존 ConnectionStrings:DefaultConnection 설정을 그대로 사용.
var dbUrlFile = builder.Configuration["ConnectionStrings:DefaultConnection_FILE"];
if (!string.IsNullOrWhiteSpace(dbUrlFile) && File.Exists(dbUrlFile))
{
    builder.Configuration["ConnectionStrings:DefaultConnection"] =
        File.ReadAllText(dbUrlFile).Trim();
}

builder.Services.Configure<HostOptions>(options =>
{
    options.ShutdownTimeout = TimeSpan.FromSeconds(65); // 도커 stop_grace_period(60초)보다 길게 잡아 진행 중 요청을 빠뜨리지 않고 처리
});

// 서비스에 헬스체크 추가
builder.Services.AddHealthChecks();
builder.Services.AddControllers();
builder.Services.AddRazorPages();

builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IUserService, UserService>(); // 서비스 추가함!

var app = builder.Build();

// 헬스체크 엔드포인트 (/health) — deploy.sh / LB probe 전용.
// 보안상 외부 정찰 정보(color·imageTag·gitSha·host 등)는 노출하지 않고 상태(200/"Healthy")만 반환한다.
app.MapHealthChecks("/health");

app.MapControllers();
app.MapRazorPages();

// 버전 확인용 간단한 API (Blue/Green 구분용)
//app.MapGet("/", () => "Hello! This is Version 16.0 (Blue)");
//app.MapGet("/", () => "Hello! This is Version 17.0 (Green)");

app.Run();
