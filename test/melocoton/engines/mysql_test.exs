defmodule Melocoton.Engines.MysqlTest do
  use ExUnit.Case, async: false

  alias Melocoton.ContainerHelper
  alias Melocoton.DatabaseClient
  alias Melocoton.Engines.Mysql
  alias Melocoton.Engines.{TableMeta, TableStructure}
  alias Melocoton.Test.DBPool

  @moduletag :container

  # NOTE: CREATE FUNCTION requires SUPER privilege when binary logging is
  # enabled (which the testcontainers image enables by default), and the
  # test user lacks it. Procedures are not subject to that restriction and
  # exercise the same `get_functions/1` query path.
  @seed_sql [
    "CREATE TABLE users (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255) NOT NULL, email VARCHAR(255) UNIQUE)",
    "CREATE TABLE posts (id INT AUTO_INCREMENT PRIMARY KEY, user_id INT, title VARCHAR(255), body TEXT, FOREIGN KEY (user_id) REFERENCES users(id))",
    "CREATE INDEX idx_posts_user_id ON posts(user_id)",
    "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')",
    "INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')",
    "INSERT INTO posts (user_id, title, body) VALUES (1, 'Hello', 'World')",
    "CREATE PROCEDURE noop_proc() SELECT 1"
  ]

  setup_all do
    {container, conn} = ContainerHelper.start_mysql(@seed_sql)
    conn_params = Testcontainers.MySqlContainer.connection_parameters(container)

    url =
      "mysql://#{conn_params[:username]}:#{conn_params[:password]}@#{conn_params[:hostname]}:#{conn_params[:port]}/#{conn_params[:database]}"

    on_exit(fn ->
      DBPool.stop(conn.pid)
      Testcontainers.stop_container(container.container_id)
    end)

    %{conn: conn, container_url: url}
  end

  describe "get_tables/1" do
    test "returns list of tables with columns", %{conn: conn} do
      {:ok, tables} = Mysql.get_tables(conn)

      table_names = Enum.map(tables, & &1.name)
      assert "users" in table_names
      assert "posts" in table_names

      users_table = Enum.find(tables, &(&1.name == "users"))
      col_names = Enum.map(users_table.cols, & &1.name)
      assert "id" in col_names
      assert "name" in col_names
      assert "email" in col_names
    end

    test "tables are sorted by name", %{conn: conn} do
      {:ok, tables} = Mysql.get_tables(conn)
      names = Enum.map(tables, & &1.name)
      assert names == Enum.sort(names)
    end
  end

  describe "get_indexes/1" do
    test "returns indexes", %{conn: conn} do
      {:ok, indexes} = Mysql.get_indexes(conn)

      index_names = Enum.map(indexes, & &1.name)
      assert "idx_posts_user_id" in index_names

      idx = Enum.find(indexes, &(&1.name == "idx_posts_user_id"))
      assert idx.table == "posts"
    end

    test "includes primary key indexes", %{conn: conn} do
      {:ok, indexes} = Mysql.get_indexes(conn)
      primary_indexes = Enum.filter(indexes, &(&1.name == "PRIMARY"))
      tables = Enum.map(primary_indexes, & &1.table)
      assert "users" in tables
      assert "posts" in tables
    end
  end

  describe "get_table_meta/2" do
    test "returns columns and pk for users table", %{conn: conn} do
      %TableMeta{} = meta = Mysql.get_table_meta(conn, "users")

      assert "id" in meta.columns
      assert "name" in meta.columns
      assert "email" in meta.columns
      assert meta.pk_columns == ["id"]
    end

    test "returns column types", %{conn: conn} do
      %TableMeta{} = meta = Mysql.get_table_meta(conn, "users")

      assert meta.column_types["id"] == "int"
      assert meta.column_types["name"] == "varchar"
    end
  end

  describe "get_table_structure/2" do
    test "returns full structure for posts table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "posts")

      assert structure.pk_columns == ["id"]
      assert length(structure.columns) == 4

      assert length(structure.foreign_keys) == 1
      fk = hd(structure.foreign_keys)
      assert fk.column == "user_id"
      assert fk.foreign_table == "users"
      assert fk.foreign_column == "id"
    end

    test "returns indexes for the table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "posts")

      index_names = Enum.map(structure.indexes, & &1.name)
      assert "idx_posts_user_id" in index_names
    end

    test "returns unique constraints", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "users")

      unique_names = Enum.map(structure.unique_constraints, & &1.name)
      assert Enum.any?(unique_names, &String.contains?(&1, "email"))
    end

    test "returns referenced_by for users table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "users")

      assert [_ | _] = structure.referenced_by
      ref = hd(structure.referenced_by)
      assert ref.foreign_table == "posts"
    end

    test "returns size information", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "users")

      assert is_map(structure.size)
      assert Map.has_key?(structure.size, "total_size")
    end

    test "returns check constraints", %{conn: conn} do
      Melocoton.Connection.query(conn, """
      CREATE TABLE with_checks (
        id INT AUTO_INCREMENT PRIMARY KEY,
        age INT,
        status VARCHAR(20),
        CONSTRAINT age_positive CHECK (age > 0),
        CONSTRAINT valid_status CHECK (status IN ('active', 'inactive'))
      )
      """)

      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "with_checks")

      assert length(structure.check_constraints) >= 2
      names = Enum.map(structure.check_constraints, & &1.name)
      assert "age_positive" in names
      assert "valid_status" in names
    end

    test "returns empty check constraints when none exist", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Mysql.get_table_structure(conn, "posts")

      assert structure.check_constraints == []
    end
  end

  describe "get_estimated_count/2" do
    test "returns a count for users table", %{conn: conn} do
      count = Mysql.get_estimated_count(conn, "users")
      assert is_integer(count)
      assert count >= 0
    end

    test "returns zero for empty table", %{conn: conn} do
      {:ok, _} =
        Melocoton.Connection.query(
          conn,
          "CREATE TABLE IF NOT EXISTS empty_table (id INT AUTO_INCREMENT PRIMARY KEY)"
        )

      count = Mysql.get_estimated_count(conn, "empty_table")
      assert count == 0
    end
  end

  describe "test_connection/1" do
    test "returns :ok for valid connection", %{container_url: url} do
      :sys.replace_state(Melocoton.Pool, fn _ -> %{} end)
      database = %{id: :test_mysql, type: :mysql, url: url}
      assert Mysql.test_connection(database) == :ok
    end

    @tag :capture_log
    test "returns error for invalid connection" do
      :sys.replace_state(Melocoton.Pool, fn _ -> %{} end)
      database = %{id: :test_mysql_bad, type: :mysql, url: "mysql://localhost:1/nonexistent"}
      assert {:error, _reason} = Mysql.test_connection(database)
    end
  end

  describe "query execution via DatabaseClient" do
    test "executes SELECT and returns normalized result", %{conn: conn} do
      {:ok, result, meta} = DatabaseClient.query(conn, "SELECT name FROM users ORDER BY id")

      assert result.cols == ["name"]
      assert length(result.rows) == 2
      assert hd(result.rows)["name"] == "Alice"
      assert meta.total_time >= 0
    end

    test "returns error for invalid SQL", %{conn: conn} do
      {:error, message} = DatabaseClient.query(conn, "SELECT * FROM nonexistent_table")
      assert is_binary(message)
    end

    # These cover the text-protocol branch of Connection.query/3 for MySQL.
    # MyXQL's prepared-statement protocol rejects routine/trigger DDL with
    # ER_UNSUPPORTED_PS, so editor queries with no binds are routed through
    # the text protocol. Regression tests for that split live here.
    test "creates a stored procedure via the editor path", %{conn: conn} do
      drop_sql = "DROP PROCEDURE IF EXISTS editor_proc"
      create_sql = "CREATE PROCEDURE editor_proc() SELECT 1"

      assert {:ok, _, _} = DatabaseClient.query(conn, drop_sql)
      assert {:ok, _, _} = DatabaseClient.query(conn, create_sql)

      {:ok, functions} = Mysql.get_functions(conn)
      assert Enum.any?(functions, &(&1.name == "editor_proc" and &1.kind == :procedure))

      # cleanup so the assertion doesn't leak into other tests
      assert {:ok, _, _} = DatabaseClient.query(conn, drop_sql)
    end

    test "parameterized engine queries still work alongside DDL", %{conn: conn} do
      # Regression guard: confirms the `params == []` vs `params != []`
      # protocol split in Connection.query doesn't break the bound path.
      assert %TableMeta{columns: columns} = Mysql.get_table_meta(conn, "users")
      assert "email" in columns
    end
  end

  describe "get_functions/1" do
    test "returns stored procedures", %{conn: conn} do
      {:ok, functions} = Mysql.get_functions(conn)

      proc = Enum.find(functions, &(&1.name == "noop_proc"))
      assert proc != nil
      assert proc.kind == :procedure
      assert proc.id == "PROCEDURE::noop_proc"
    end
  end

  describe "get_function_definition/2" do
    test "returns SHOW CREATE output for a procedure", %{conn: conn} do
      {:ok, definition} = Mysql.get_function_definition(conn, "PROCEDURE::noop_proc")

      assert definition =~ "noop_proc"
    end

    test "returns error for malformed id", %{conn: conn} do
      assert {:error, _} = Mysql.get_function_definition(conn, "not-a-valid-id")
    end
  end
end
