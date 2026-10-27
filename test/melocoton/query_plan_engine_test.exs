defmodule Melocoton.QueryPlanEngineTest do
  use ExUnit.Case, async: false

  alias Melocoton.{ContainerHelper, DatabaseClient, QueryPlan}
  alias Melocoton.Test.DBPool

  @tag :container
  test "PostgreSQL native text and JSON plans expose comparable metrics" do
    {container, conn} =
      ContainerHelper.start_postgres([
        "CREATE TABLE plan_users (id integer, name text)",
        "INSERT INTO plan_users VALUES (1, 'Alice')"
      ])

    on_exit(fn ->
      DBPool.stop(conn.pid)
      Testcontainers.stop_container(container.container_id)
    end)

    for prefix <- ["EXPLAIN", "EXPLAIN (FORMAT JSON)", "EXPLAIN (ANALYZE, FORMAT JSON)"] do
      sql = "#{prefix} SELECT * FROM plan_users ORDER BY name"
      assert {:ok, result, _stats} = DatabaseClient.query(conn, sql)
      assert %{nodes: [_ | _], metric: metric} = QueryPlan.from_result(sql, result, :postgres)
      assert metric in [:cost, :time]
    end
  end

  @tag :container
  test "MySQL native tabular, JSON, TREE and ANALYZE plans are visualized" do
    {container, conn} =
      ContainerHelper.start_mysql([
        "CREATE TABLE plan_users (id integer, name varchar(50))",
        "INSERT INTO plan_users VALUES (1, 'Alice')"
      ])

    on_exit(fn ->
      DBPool.stop(conn.pid)
      Testcontainers.stop_container(container.container_id)
    end)

    for prefix <- ["EXPLAIN", "EXPLAIN FORMAT=JSON", "EXPLAIN FORMAT=TREE", "EXPLAIN ANALYZE"] do
      sql = "#{prefix} SELECT * FROM plan_users ORDER BY name"
      assert {:ok, result, _stats} = DatabaseClient.query(conn, sql)
      assert %{nodes: [_ | _], metric: metric} = QueryPlan.from_result(sql, result, :mysql)
      assert metric in [:cost, :time, :rows]
    end
  end
end
