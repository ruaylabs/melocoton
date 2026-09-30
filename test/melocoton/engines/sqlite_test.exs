defmodule Melocoton.Engines.SqliteTest do
  use ExUnit.Case, async: true

  alias Melocoton.Connection
  alias Melocoton.DatabaseClient
  alias Melocoton.Engines.Sqlite
  alias Melocoton.Engines.{TableMeta, TableStructure}
  alias Melocoton.Test.DBPool

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "melocoton_sqlite_engine_test_#{System.unique_integer([:positive])}.db"
      )

    {:ok, raw_db} = Exqlite.Sqlite3.open(db_path)

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT UNIQUE)"
      )

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        "CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER REFERENCES users(id), title TEXT, body TEXT)"
      )

    :ok = Exqlite.Sqlite3.execute(raw_db, "CREATE INDEX idx_posts_user_id ON posts(user_id)")

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')"
      )

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        "INSERT INTO users (name, email) VALUES ('Bob', 'bob@example.com')"
      )

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        "INSERT INTO posts (user_id, title, body) VALUES (1, 'Hello', 'World')"
      )

    :ok = Exqlite.Sqlite3.execute(raw_db, "CREATE TABLE empty_table (id INTEGER PRIMARY KEY)")

    :ok =
      Exqlite.Sqlite3.execute(
        raw_db,
        """
        CREATE TRIGGER users_name_not_empty BEFORE INSERT ON users
        BEGIN
          SELECT CASE WHEN LENGTH(NEW.name) = 0
            THEN RAISE(ABORT, 'name cannot be empty') END;
        END;
        """
      )

    Exqlite.Sqlite3.close(raw_db)

    {:ok, pid} = DBConnection.start_link(Exqlite.Connection, database: db_path, pool_size: 1)
    conn = %Connection{pid: pid, type: :sqlite}

    on_exit(fn ->
      DBPool.stop(pid)
      File.rm(db_path)
    end)

    %{conn: conn, db_path: db_path}
  end

  describe "get_tables/1" do
    test "returns list of tables with columns", %{conn: conn} do
      {:ok, tables} = Sqlite.get_tables(conn)

      table_names = Enum.map(tables, & &1.name)
      assert "users" in table_names
      assert "posts" in table_names
      assert "empty_table" in table_names

      users_table = Enum.find(tables, &(&1.name == "users"))
      col_names = Enum.map(users_table.cols, & &1.name)
      assert "id" in col_names
      assert "name" in col_names
      assert "email" in col_names
    end

    test "excludes sqlite internal tables", %{conn: conn} do
      {:ok, tables} = Sqlite.get_tables(conn)
      table_names = Enum.map(tables, & &1.name)

      refute Enum.any?(table_names, &String.starts_with?(&1, "sqlite_"))
    end

    test "includes column types", %{conn: conn} do
      {:ok, tables} = Sqlite.get_tables(conn)

      users_table = Enum.find(tables, &(&1.name == "users"))
      id_col = Enum.find(users_table.cols, &(&1.name == "id"))
      assert id_col.type == "INTEGER"
    end
  end

  describe "get_indexes/1" do
    test "returns user-created indexes", %{conn: conn} do
      {:ok, indexes} = Sqlite.get_indexes(conn)

      index_names = Enum.map(indexes, & &1.name)
      assert "idx_posts_user_id" in index_names

      idx = Enum.find(indexes, &(&1.name == "idx_posts_user_id"))
      assert idx.table == "posts"
    end

    test "includes auto-created indexes", %{conn: conn} do
      {:ok, indexes} = Sqlite.get_indexes(conn)
      tables = Enum.map(indexes, & &1.table)

      assert "users" in tables
    end
  end

  describe "get_table_meta/2" do
    test "returns columns and pk for users table", %{conn: conn} do
      %TableMeta{} = meta = Sqlite.get_table_meta(conn, "users")

      assert "id" in meta.columns
      assert "name" in meta.columns
      assert "email" in meta.columns
      assert meta.pk_columns == ["id"]
    end

    test "returns column types", %{conn: conn} do
      %TableMeta{} = meta = Sqlite.get_table_meta(conn, "users")

      assert meta.column_types["id"] == "integer"
      assert meta.column_types["name"] == "text"
    end

    test "returns empty struct for nonexistent table", %{conn: conn} do
      %TableMeta{} = meta = Sqlite.get_table_meta(conn, "nonexistent")

      assert meta.columns == []
      assert meta.pk_columns == []
    end
  end

  describe "get_table_structure/2" do
    test "returns full structure for posts table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "posts")

      assert structure.pk_columns == ["id"]
      assert length(structure.columns) == 4

      assert length(structure.foreign_keys) == 1
      fk = hd(structure.foreign_keys)
      assert fk.column == "user_id"
      assert fk.foreign_table == "users"
      assert fk.foreign_column == "id"
    end

    test "returns indexes for the table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "posts")

      index_names = Enum.map(structure.indexes, & &1.name)
      assert "idx_posts_user_id" in index_names
    end

    test "returns unique constraints", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "users")

      unique_cols =
        Enum.flat_map(structure.unique_constraints, & &1.columns)

      assert "email" in unique_cols
    end

    test "returns referenced_by for users table", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "users")

      assert [_ | _] = structure.referenced_by
      ref = hd(structure.referenced_by)
      assert ref.foreign_table == "posts"
    end

    test "returns create statement", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "users")

      assert structure.create_statement =~ "CREATE TABLE users"
    end

    test "returns check constraints from named constraints", %{conn: conn} do
      Connection.query(conn, """
      CREATE TABLE with_checks (
        id INTEGER PRIMARY KEY,
        age INTEGER CONSTRAINT age_positive CHECK(age > 0),
        status TEXT CONSTRAINT valid_status CHECK(status IN ('active', 'inactive'))
      )
      """)

      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "with_checks")

      assert length(structure.check_constraints) == 2
      names = Enum.map(structure.check_constraints, & &1.name)
      assert "age_positive" in names
      assert "valid_status" in names

      age_check = Enum.find(structure.check_constraints, &(&1.name == "age_positive"))
      assert age_check.definition =~ "age > 0"
    end

    test "returns check constraints from unnamed constraints", %{conn: conn} do
      Connection.query(conn, """
      CREATE TABLE with_bare_checks (
        id INTEGER PRIMARY KEY,
        quantity INTEGER CHECK(quantity >= 0)
      )
      """)

      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "with_bare_checks")

      assert length(structure.check_constraints) == 1
      check = hd(structure.check_constraints)
      assert check.name == "check_1"
      assert check.definition =~ "quantity >= 0"
    end

    test "returns empty check constraints when none exist", %{conn: conn} do
      {:ok, %TableStructure{} = structure} = Sqlite.get_table_structure(conn, "users")

      assert structure.check_constraints == []
    end
  end

  describe "get_estimated_count/2" do
    test "returns exact count for table with rows", %{conn: conn} do
      count = Sqlite.get_estimated_count(conn, "users")
      assert count == 2
    end

    test "returns zero for empty table", %{conn: conn} do
      count = Sqlite.get_estimated_count(conn, "empty_table")
      assert count == 0
    end
  end

  describe "test_connection/1" do
    test "returns :ok for existing file", %{db_path: db_path} do
      database = %{url: db_path}
      assert Sqlite.test_connection(database) == :ok
    end

    test "returns error for nonexistent file" do
      database = %{url: "/tmp/nonexistent_#{System.unique_integer([:positive])}.db"}
      assert {:error, _reason} = Sqlite.test_connection(database)
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
  end

  describe "get_functions/1" do
    test "returns an empty list (SQLite has no stored functions)", %{conn: conn} do
      assert {:ok, []} = Sqlite.get_functions(conn)
    end
  end

  describe "get_function_definition/2" do
    test "returns an error", %{conn: conn} do
      assert {:error, _} = Sqlite.get_function_definition(conn, "anything")
    end
  end

  describe "get_triggers/1" do
    test "returns user-defined triggers with their table", %{conn: conn} do
      {:ok, triggers} = Sqlite.get_triggers(conn)

      trg = Enum.find(triggers, &(&1.name == "users_name_not_empty"))
      assert trg != nil
      assert trg.table == "users"
      assert trg.id == "users_name_not_empty"
    end
  end

  describe "get_trigger_definition/2" do
    test "returns the CREATE TRIGGER body", %{conn: conn} do
      {:ok, definition} = Sqlite.get_trigger_definition(conn, "users_name_not_empty")

      assert definition =~ "TRIGGER users_name_not_empty"
      assert definition =~ "BEFORE INSERT ON users"
      assert definition =~ "name cannot be empty"
    end

    test "returns error for unknown trigger", %{conn: conn} do
      assert {:error, _} = Sqlite.get_trigger_definition(conn, "nope")
    end
  end
end
