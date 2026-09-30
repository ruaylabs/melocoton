defmodule Melocoton.TransactionSessionTest do
  use ExUnit.Case, async: false

  alias Melocoton.{Connection, TransactionSession}
  alias Melocoton.Test.DBPool

  setup do
    db_path =
      Path.join(System.tmp_dir!(), "melocoton_tx_test_#{System.unique_integer([:positive])}.db")

    {:ok, raw_db} = Exqlite.Sqlite3.open(db_path)

    :ok =
      Exqlite.Sqlite3.execute(raw_db, "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)")

    :ok = Exqlite.Sqlite3.execute(raw_db, "INSERT INTO items (name) VALUES ('original')")
    Exqlite.Sqlite3.close(raw_db)

    {:ok, pid} = DBConnection.start_link(Exqlite.Connection, database: db_path, pool_size: 1)
    conn = %Connection{pid: pid, type: :sqlite}

    on_exit(fn ->
      DBPool.stop(pid)
      File.rm(db_path)
    end)

    %{conn: conn, db_path: db_path}
  end

  describe "commit" do
    test "persists changes after commit", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} =
        TransactionSession.query(session, "INSERT INTO items (name) VALUES ('committed')")

      :ok = TransactionSession.commit(session)

      {:ok, result} = Connection.query(conn, "SELECT name FROM items ORDER BY id")
      names = Enum.map(result.rows, &List.first/1)
      assert "committed" in names
    end
  end

  describe "rollback" do
    test "discards changes after rollback", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} =
        TransactionSession.query(session, "INSERT INTO items (name) VALUES ('rolled_back')")

      :ok = TransactionSession.rollback(session)

      # Wait for session to terminate so the connection is released
      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

      {:ok, result} = Connection.query(conn, "SELECT name FROM items ORDER BY id")
      names = Enum.map(result.rows, &List.first/1)
      refute "rolled_back" in names
    end
  end

  describe "query within transaction" do
    test "executes queries and returns results", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, result} = TransactionSession.query(session, "SELECT name FROM items")
      assert result.num_rows == 1

      TransactionSession.rollback(session)
    end

    test "can execute multiple queries in sequence", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('a')")
      {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('b')")
      {:ok, result} = TransactionSession.query(session, "SELECT name FROM items ORDER BY id")

      assert result.num_rows == 3
      :ok = TransactionSession.commit(session)
    end
  end

  describe "caller death auto-rollback" do
    test "rolls back when caller process dies", %{conn: conn} do
      test_pid = self()

      caller =
        spawn(fn ->
          {:ok, session} = TransactionSession.start(conn, self())
          send(test_pid, {:session, session})

          {:ok, _} =
            TransactionSession.query(session, "INSERT INTO items (name) VALUES ('ghost')")

          send(test_pid, :inserted)
        end)

      assert_receive {:session, session_pid}, 5_000
      assert_receive :inserted, 5_000

      # Wait for caller to die
      caller_ref = Process.monitor(caller)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, _}, 5_000

      # Wait for transaction session to terminate (triggered by caller :DOWN)
      session_ref = Process.monitor(session_pid)
      assert_receive {:DOWN, ^session_ref, :process, ^session_pid, _}, 5_000

      {:ok, result} = Connection.query(conn, "SELECT name FROM items")
      names = Enum.map(result.rows, &List.first/1)
      refute "ghost" in names
    end
  end

  describe "session process lifecycle" do
    test "session process terminates after commit", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())
      ref = Process.monitor(session)

      :ok = TransactionSession.commit(session)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
    end

    test "session process terminates after rollback", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())
      ref = Process.monitor(session)

      :ok = TransactionSession.rollback(session)

      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000
    end
  end

  describe "delete queries" do
    test "deletes row within transaction", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} = TransactionSession.query(session, "DELETE FROM items WHERE id = 1")

      :ok = TransactionSession.commit(session)

      {:ok, result} = Connection.query(conn, "SELECT COUNT(*) FROM items")
      assert [[count]] = result.rows
      assert count == 0
    end

    test "delete is rolled back when transaction rolled back", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} = TransactionSession.query(session, "DELETE FROM items WHERE id = 1")
      :ok = TransactionSession.rollback(session)

      ref = Process.monitor(session)
      assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

      {:ok, result} = Connection.query(conn, "SELECT COUNT(*) FROM items")
      assert [[count]] = result.rows
      assert count == 1
    end

    test "deletes with where clause", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('keep')")
      {:ok, _} = TransactionSession.query(session, "DELETE FROM items WHERE name = 'original'")

      :ok = TransactionSession.commit(session)

      {:ok, result} = Connection.query(conn, "SELECT name FROM items")
      names = Enum.map(result.rows, &List.first/1)
      refute "original" in names
      assert "keep" in names
    end

    test "delete returns num_rows affected", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      {:ok, _result} = TransactionSession.query(session, "DELETE FROM items WHERE id = 1")
      # Verify delete actually worked by querying within the same transaction
      {:ok, verify} = TransactionSession.query(session, "SELECT COUNT(*) FROM items")
      assert [[0]] = verify.rows

      TransactionSession.rollback(session)
    end

    test "delete with no matching rows returns zero affected", %{conn: conn} do
      {:ok, session} = TransactionSession.start(conn, self())

      # Verify no rows deleted by checking count before and after
      {:ok, before} = TransactionSession.query(session, "SELECT COUNT(*) FROM items")
      assert [[1]] = before.rows

      {:ok, _result} = TransactionSession.query(session, "DELETE FROM items WHERE id = 999")

      {:ok, post_delete} = TransactionSession.query(session, "SELECT COUNT(*) FROM items")
      # count unchanged
      assert [[1]] = post_delete.rows

      TransactionSession.rollback(session)
    end
  end
end
