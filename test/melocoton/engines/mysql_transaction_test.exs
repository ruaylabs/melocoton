defmodule Melocoton.Engines.MysqlTransactionTest do
  use ExUnit.Case, async: false

  alias Melocoton.{Connection, TransactionSession}
  alias Melocoton.ContainerHelper
  alias Melocoton.Test.DBPool

  @moduletag :container

  @seed_sql [
    "CREATE TABLE items (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(255))"
  ]

  setup_all do
    {container, conn} = ContainerHelper.start_mysql(@seed_sql)

    on_exit(fn ->
      DBPool.stop(conn.pid)
      Testcontainers.stop_container(container.container_id)
    end)

    %{conn: conn, container: container}
  end

  setup %{conn: conn} do
    Connection.query(conn, "TRUNCATE TABLE items")
    Connection.query(conn, "INSERT INTO items (name) VALUES ('original')")
    :ok
  end

  test "commit persists changes", %{conn: conn} do
    {:ok, session} = TransactionSession.start(conn, self())
    {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('committed')")
    :ok = TransactionSession.commit(session)

    {:ok, result} = Connection.query(conn, "SELECT name FROM items ORDER BY id")
    names = Enum.map(result.rows, fn [name] -> name end)
    assert "committed" in names
  end

  test "rollback discards changes", %{conn: conn} do
    {:ok, session} = TransactionSession.start(conn, self())

    {:ok, _} =
      TransactionSession.query(session, "INSERT INTO items (name) VALUES ('rolled_back')")

    :ok = TransactionSession.rollback(session)

    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

    {:ok, result} = Connection.query(conn, "SELECT name FROM items ORDER BY id")
    names = Enum.map(result.rows, fn [name] -> name end)
    refute "rolled_back" in names
  end

  test "rollback restores deleted data", %{conn: conn} do
    {:ok, session} = TransactionSession.start(conn, self())

    {:ok, _} = TransactionSession.query(session, "DELETE FROM items WHERE name = 'original'")

    :ok = TransactionSession.rollback(session)

    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, _}, 5_000

    {:ok, result} = Connection.query(conn, "SELECT name FROM items ORDER BY id")
    names = Enum.map(result.rows, fn [name] -> name end)
    assert "original" in names
  end

  test "multiple queries in sequence", %{conn: conn} do
    {:ok, session} = TransactionSession.start(conn, self())
    {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('a')")
    {:ok, _} = TransactionSession.query(session, "INSERT INTO items (name) VALUES ('b')")
    {:ok, result} = TransactionSession.query(session, "SELECT name FROM items ORDER BY id")

    assert result.num_rows == 3
    :ok = TransactionSession.commit(session)
  end
end
