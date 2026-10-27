defmodule Melocoton.QueryPlanTest do
  use ExUnit.Case, async: true

  alias Melocoton.QueryPlan

  defp result(column, values) do
    %{cols: [column], rows: Enum.map(values, &%{column => &1}), num_rows: length(values)}
  end

  test "detects EXPLAIN with leading comments but not similar identifiers or later statements" do
    assert QueryPlan.explain?(" -- note\n /* plan */ EXPLAIN ANALYZE SELECT 1")
    assert QueryPlan.explain?("explain (format json) SELECT 1")
    refute QueryPlan.explain?(nil)
    refute QueryPlan.explain?("explainable")
    refute QueryPlan.explain?("SELECT 1; EXPLAIN SELECT 2")
  end

  test "parses PostgreSQL text operators and their nesting" do
    output =
      result("QUERY PLAN", [
        "Hash Join  (cost=1.00..20.00 rows=2 width=8)",
        "  Hash Cond: (u.id = p.user_id)",
        "  ->  Seq Scan on users u  (cost=0.00..10.00 rows=2 width=4)",
        "  ->  Hash  (cost=1.00..1.00 rows=1 width=4)",
        "        ->  Seq Scan on posts p  (cost=0.00..1.00 rows=1 width=4)",
        "Planning Time: 0.100 ms",
        "Execution Time: 0.200 ms"
      ])

    assert %{nodes: [join, users, hash, posts], truncated: false} =
             QueryPlan.from_result("EXPLAIN ANALYZE SELECT 1", output, :postgres)

    assert join.label == "Hash Join"
    assert join.parent == nil
    assert users.parent == join.id
    assert hash.parent == join.id
    assert posts.parent == hash.id
    assert users.details =~ "rows=2"
  end

  test "parses PostgreSQL JSON whether returned decoded or as JSON text" do
    document = [
      %{
        "Plan" => %{
          "Node Type" => "Limit",
          "Plan Rows" => 1,
          "Plans" => [
            %{
              "Node Type" => "Index Scan",
              "Relation Name" => "users",
              "Index Name" => "users_pkey",
              "Actual Rows" => 1
            }
          ]
        }
      }
    ]

    for value <- [document, Jason.encode!(document), Enum.map(document, &Jason.encode!/1)] do
      assert %{nodes: [limit, scan]} =
               QueryPlan.from_result(
                 "EXPLAIN (FORMAT JSON) SELECT 1",
                 result("QUERY PLAN", [value]),
                 :postgres
               )

      assert scan.parent == limit.id
      assert scan.label == "Index Scan · users · users_pkey"
      assert scan.details =~ "Actual Rows: 1"
    end
  end

  test "uses SQLite parent IDs, not row positions, and supports multiple roots" do
    output = %{
      cols: ~w(id parent notused detail),
      num_rows: 3,
      rows: [
        %{"id" => 2, "parent" => 0, "detail" => "SCAN users"},
        %{"id" => 8, "parent" => 2, "detail" => "SEARCH posts USING INDEX posts_user_id"},
        %{"id" => 12, "parent" => 0, "detail" => "USE TEMP B-TREE FOR ORDER BY"}
      ]
    }

    assert %{nodes: [users, posts, sort]} =
             QueryPlan.from_result("EXPLAIN QUERY PLAN SELECT 1", output, :sqlite)

    assert users.parent == nil
    assert posts.parent == 2
    assert sort.parent == nil
    assert QueryPlan.from_result("EXPLAIN SELECT 1", result("opcode", ["Init"]), :sqlite) == nil
  end

  test "parses MySQL TREE output" do
    output =
      result("EXPLAIN", [
        "-> Limit: 1 row(s)  (cost=1.00 rows=1)\n    -> Table scan on users  (cost=1.00 rows=2)"
      ])

    assert %{nodes: [limit, scan]} =
             QueryPlan.from_result("EXPLAIN FORMAT=TREE SELECT 1", output, :mysql)

    assert scan.parent == limit.id
    assert scan.label == "Table scan on users"
  end

  test "parses MySQL JSON operation nesting" do
    json =
      Jason.encode!(%{
        "query_block" => %{
          "nested_loop" => [
            %{
              "table" => %{
                "table_name" => "users",
                "access_type" => "ALL",
                "rows_examined_per_scan" => 10
              }
            },
            %{
              "table" => %{
                "table_name" => "posts",
                "access_type" => "ref",
                "key" => "posts_user_id"
              }
            }
          ]
        }
      })

    assert %{nodes: [block, join, users, posts]} =
             QueryPlan.from_result(
               "EXPLAIN FORMAT=JSON SELECT 1",
               result("EXPLAIN", [json]),
               :mysql
             )

    assert join.parent == block.id
    assert users.parent == join.id
    assert posts.parent == join.id
    assert users.label == "ALL · users"
    assert posts.details =~ "posts_user_id"
  end

  test "does not invent a tree for unsupported, empty, or ordinary query output" do
    output = result("QUERY PLAN", ["Seq Scan on users  (cost=0.00..1.00 rows=1 width=4)"])
    assert QueryPlan.from_result("SELECT 1", output, :postgres) == nil

    assert QueryPlan.from_result("EXPLAIN SELECT 1", result("EXPLAIN", ["{broken JSON"]), :mysql) ==
             nil

    assert QueryPlan.from_result("EXPLAIN SELECT 1", result("QUERY PLAN", []), :postgres) == nil

    assert QueryPlan.from_result(
             "EXPLAIN SELECT 1",
             %{cols: ~w(id table), rows: [], num_rows: 0},
             :mysql
           ) == nil
  end

  test "highlights exclusive PostgreSQL costs instead of the cumulative parent cost" do
    json =
      Jason.encode!([
        %{
          "Plan" => %{
            "Node Type" => "Append",
            "Total Cost" => 101,
            "Plans" => [
              %{"Node Type" => "Seq Scan", "Relation Name" => "large", "Total Cost" => 100},
              %{"Node Type" => "Index Scan", "Relation Name" => "small", "Total Cost" => 1}
            ]
          }
        }
      ])

    assert %{metric: :cost, nodes: [parent, large, small]} =
             QueryPlan.from_result(
               "EXPLAIN (FORMAT JSON) SELECT 1",
               result("QUERY PLAN", [json]),
               :postgres
             )

    assert parent.score == 0
    refute parent.hotspot
    assert large.score == 100
    assert large.relative == 100
    assert large.hotspot
    refute small.hotspot
  end

  test "actual timings account for loops and take precedence over estimated costs" do
    for {type, cost} <- [{:postgres, "0.00.."}, {:mysql, ""}] do
      output =
        result("EXPLAIN", [
          "-> Nested loop (cost=#{cost}1000 rows=1) (actual time=0.1..10 rows=1 loops=1)",
          "    -> Scan outer (cost=#{cost}500 rows=1) (actual time=0.1..1 rows=1 loops=1)",
          "    -> Scan inner (cost=#{cost}1 rows=1) (actual time=0.1..0.8 rows=1 loops=10)"
        ])

      assert %{metric: :time, nodes: [parent, outer, inner]} =
               QueryPlan.from_result("EXPLAIN ANALYZE SELECT 1", output, type)

      assert parent.score == 1
      assert outer.score == 1
      assert inner.score == 8
      assert inner.hotspot
      refute parent.hotspot
      refute outer.hotspot
    end
  end

  test "zero or never-executed timing does not fall back to imaginary measured expense" do
    output =
      result("QUERY PLAN", [
        "Append (cost=0.00..100 rows=1) (actual time=0.0..0.0 rows=0 loops=1)",
        "  -> Index Scan (cost=0.00..99 rows=1) (never executed)"
      ])

    assert %{metric: :time, nodes: nodes} =
             QueryPlan.from_result("EXPLAIN ANALYZE SELECT 1", output, :postgres)

    assert Enum.all?(nodes, &(&1.score == 0 && !&1.hotspot && &1.relative == 0))
  end

  test "TIMING OFF does not mislabel estimated cost as measured timing" do
    output =
      result("QUERY PLAN", [
        "Append (cost=0.00..1000 rows=1) (actual rows=1 loops=1)",
        "  -> Index Scan (cost=0.00..999 rows=1) (never executed)"
      ])

    assert %{metric: :cost, nodes: [_parent, skipped]} =
             QueryPlan.from_result("EXPLAIN (ANALYZE, TIMING OFF) SELECT 1", output, :postgres)

    assert skipped.score == 0
    refute skipped.hotspot
  end

  test "MySQL JSON uses local read/evaluation costs, not cumulative prefix costs" do
    json =
      Jason.encode!(%{
        "query_block" => %{
          "cost_info" => %{"query_cost" => "1000"},
          "nested_loop" => [
            %{
              "table" => %{
                "table_name" => "large",
                "access_type" => "ALL",
                "cost_info" => %{"read_cost" => "40", "eval_cost" => "10", "prefix_cost" => "50"}
              }
            },
            %{
              "table" => %{
                "table_name" => "small",
                "access_type" => "ref",
                "cost_info" => %{"read_cost" => "1", "eval_cost" => "1", "prefix_cost" => "1000"}
              }
            }
          ]
        }
      })

    assert %{metric: :cost, nodes: [root, _join, large, small]} =
             QueryPlan.from_result(
               "EXPLAIN FORMAT=JSON SELECT 1",
               result("EXPLAIN", [json]),
               :mysql
             )

    assert root.score == nil
    refute root.hotspot
    assert large.score == 50
    assert large.hotspot
    assert small.score == 2
    refute small.hotspot
  end

  test "plain MySQL EXPLAIN preserves query blocks and flags scans, sorts, and large estimates" do
    output = %{
      cols: ~w(id select_type table type key rows filtered Extra),
      num_rows: 3,
      rows: [
        %{
          "id" => 1,
          "select_type" => "PRIMARY",
          "table" => "large",
          "type" => "ALL",
          "rows" => 20_000,
          "Extra" => "Using temporary; Using filesort"
        },
        %{
          "id" => 1,
          "select_type" => "PRIMARY",
          "table" => "small",
          "type" => "ref",
          "rows" => 2
        },
        %{
          "id" => 2,
          "select_type" => "SUBQUERY",
          "table" => "sub",
          "type" => "index",
          "rows" => "4"
        }
      ]
    }

    assert %{metric: :rows, nodes: [first, large, small, second, sub]} =
             QueryPlan.from_result("EXPLAIN SELECT 1", output, :mysql)

    assert large.parent == first.id
    assert small.parent == first.id
    assert sub.parent == second.id
    assert large.score == 20_000
    assert large.hotspot
    assert large.warnings == ["Full table scan", "Filesort", "Temporary table"]
    refute small.hotspot
    assert sub.score == 4
  end

  test "SQLite flags potentially costly work without inventing cost or time" do
    rows = [
      %{"id" => 2, "parent" => 0, "detail" => "SCAN users"},
      %{"id" => 3, "parent" => 0, "detail" => "USE TEMP B-TREE FOR ORDER BY"},
      %{
        "id" => 4,
        "parent" => 0,
        "detail" => "SEARCH posts USING INDEX posts_user_id (user_id=?)"
      }
    ]

    output = %{cols: ~w(id parent detail), rows: rows, num_rows: 3}

    assert %{metric: nil, nodes: [scan, sort, lookup]} =
             QueryPlan.from_result("EXPLAIN QUERY PLAN SELECT 1", output, :sqlite)

    assert scan.warnings == ["Full scan"]
    assert sort.warnings == ["Temporary B-tree"]
    assert lookup.warnings == []
    assert Enum.all?([scan, sort, lookup], &(!&1.hotspot && is_nil(&1.score)))
  end

  test "incomplete plans are not ranked and unknown child costs do not inflate parent expense" do
    output =
      result("QUERY PLAN", [
        "Limit (cost=0.00..100 rows=1)",
        "  -> Scan child (cost=0.00..99 rows=1)"
      ])

    assert %{metric: nil, truncated: true, nodes: nodes} =
             QueryPlan.from_result("EXPLAIN SELECT 1", output, :postgres, truncated: true)

    assert Enum.all?(nodes, &(!&1.hotspot && is_nil(&1.score)))
  end

  test "at most three comparable operators are highlighted" do
    output = result("QUERY PLAN", for(id <- 1..5, do: "Scan #{id} (cost=0.00..1 rows=1)"))
    assert %{nodes: nodes} = QueryPlan.from_result("EXPLAIN SELECT 1", output, :postgres)
    assert Enum.count(nodes, & &1.hotspot) == 3
  end

  test "limits chart size and marks it as partial" do
    lines = for id <- 1..250, do: "-> Table scan #{id} (cost=1 rows=1)"

    assert %{nodes: nodes, truncated: true} =
             QueryPlan.from_result(
               "EXPLAIN FORMAT=TREE SELECT 1",
               result("EXPLAIN", lines),
               :mysql
             )

    assert length(nodes) == 200
    assert Enum.all?(nodes, &(!&1.hotspot && is_nil(&1.score)))
  end
end
