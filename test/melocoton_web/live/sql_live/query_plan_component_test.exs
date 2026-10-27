defmodule MelocotonWeb.SqlLive.QueryPlanComponentTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MelocotonWeb.SqlLive.QueryPlanComponent

  test "renders a connected tree and escapes database-provided text" do
    plan = %{
      truncated: false,
      nodes: [
        %{id: 0, parent: nil, label: "Nested Loop", details: "cost=10"},
        %{id: 1, parent: 0, label: "<script>alert(1)</script>", details: "Filter: x < 10"}
      ]
    }

    html = render_component(&QueryPlanComponent.chart/1, plan: plan)
    assert html =~ "Nested Loop"
    assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert html =~ "Filter: x &lt; 10"
    assert html =~ "border-l"
    assert html =~ "border-t"
    refute html =~ "<script>"
    refute html =~ "Partial plan:"
  end

  test "expensive operations have a text badge and relative bar with honest units" do
    result = %{
      cols: ["QUERY PLAN"],
      rows: [%{"QUERY PLAN" => "Scan users (cost=0.00..100 rows=20000)"}],
      num_rows: 1
    }

    plan = Melocoton.QueryPlan.from_result("EXPLAIN SELECT 1", result, :postgres)
    html = render_component(&QueryPlanComponent.chart/1, plan: plan)
    assert html =~ ~s(data-hotspot="true")
    assert html =~ "Relative hotspot"
    assert html =~ "100 cost units"
    assert html =~ "100% of largest operator"
    assert html =~ "not milliseconds"
  end

  test "SQLite scan warnings are not presented as measured hotspots" do
    result = %{
      cols: ~w(id parent detail),
      rows: [%{"id" => 1, "parent" => 0, "detail" => "SCAN users"}],
      num_rows: 1
    }

    plan = Melocoton.QueryPlan.from_result("EXPLAIN QUERY PLAN SELECT 1", result, :sqlite)
    html = render_component(&QueryPlanComponent.chart/1, plan: plan)
    assert html =~ "Full scan"
    assert html =~ "no numeric costs or timings"
    refute html =~ "Relative hotspot"
    refute html =~ "of largest operator"
  end

  test "row estimate highlights are labeled separately from costs" do
    result = %{
      cols: ~w(table type rows),
      rows: [%{"table" => "users", "type" => "ALL", "rows" => 50_000}],
      num_rows: 1
    }

    plan = Melocoton.QueryPlan.from_result("EXPLAIN SELECT 1", result, :mysql)
    html = render_component(&QueryPlanComponent.chart/1, plan: plan)
    assert html =~ "High row estimate"
    assert html =~ "50000 estimated rows"
    refute html =~ "Relative hotspot"
  end

  test "labels incomplete plans" do
    html = render_component(&QueryPlanComponent.chart/1, plan: %{nodes: [], truncated: true})
    assert html =~ "Partial plan:"
  end
end
