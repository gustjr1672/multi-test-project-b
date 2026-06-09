using System.Data;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;

namespace Data.Application;

public interface IUserRepository
{
    Task<string?> GetUserNameByIdAsync(int id);
}

public class UserRepository : IUserRepository
{
    private readonly string _connectionString;

    public UserRepository(IConfiguration configuration)
    {
        _connectionString = configuration.GetConnectionString("DefaultConnection");
    }

    public async Task<string?> GetUserNameByIdAsync(int id)
    {
        using var connection = new SqlConnection(_connectionString);

        // 쿼리 작성 (문자열 결합이 아닌 @Id 파라미터 사용)
        string sql = "SELECT name FROM [users] WHERE id = @Id";

        using var command = new SqlCommand(sql, connection);

        // SqlParameter로 직접 바인딩하여 안전하게 처리합니다.
        command.Parameters.Add(new SqlParameter("@Id", SqlDbType.Int) { Value = id });

        await connection.OpenAsync();

        // 단일 컬럼/단일 값 조회이므로 ExecuteScalar 사용
        var result = await command.ExecuteScalarAsync();

        return result as string;
    }
}