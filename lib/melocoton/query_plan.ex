defmodule Melocoton.QueryPlan do
  @moduledoc "Parses returned EXPLAIN results without executing or rewriting SQL."

  @max_nodes 200
  @mysql_operations ~w(query_block nested_loop table ordering_operation grouping_operation duplicates_removal materialized_from_subquery union_result attached_subqueries query_specifications)

  def explain?(query) when is_binary(query) do
    query
    |> String.replace(~r/\A(?:\s+|--[^\n]*(?:\n|\z)|\/\*.*?\*\/)+/s, "")
    |> then(&Regex.match?(~r/\AEXPLAIN\b/i, &1))
  end

  def explain?(_query), do: false

  def from_result(query, result, type, opts \\ []) do
    if explain?(query) do
      nodes = parse(result, type)

      if nodes != [] do
        truncated = length(nodes) > @max_nodes or Keyword.get(opts, :truncated, false)

        nodes
        |> Enum.take(@max_nodes)
        |> analyze(type, truncated)
        |> Map.put(:truncated, truncated)
      end
    end
  end

  defp parse(%{rows: rows, cols: cols}, :mysql) when length(cols) > 1 do
    columns = Enum.map(cols, &String.downcase/1)

    if Enum.all?(~w(table type rows), &(&1 in columns)) do
      mysql_tabular(rows)
    else
      []
    end
  end

  defp parse(%{rows: rows, cols: [column]}, type) when type in [:postgres, :mysql] do
    values = Enum.map(rows, &Map.get(&1, column))

    case values |> List.first() |> decode() do
      %{"Plan" => plan} when type == :postgres ->
        postgres_nodes(plan, nil, [])

      %{"query_block" => block} when type == :mysql ->
        mysql_nodes("query_block", block, nil, [])

      _ ->
        text_nodes(values)
    end
  end

  defp parse(%{rows: rows, cols: cols}, :sqlite) do
    if Enum.all?(~w(id parent detail), &(&1 in cols)) do
      ids = MapSet.new(rows, & &1["id"])

      Enum.map(rows, fn row ->
        parent =
          if row["parent"] != row["id"] && MapSet.member?(ids, row["parent"]), do: row["parent"]

        %{id: row["id"], parent: parent, label: row["detail"], details: "", metrics: %{}}
      end)
    else
      []
    end
  end

  defp parse(_result, _type), do: []

  defp decode([first | _]), do: decode(first)

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decode(decoded)
      _ -> value
    end
  end

  defp decode(value), do: value

  defp postgres_nodes(plan, parent, nodes) when is_map(plan) and length(nodes) <= @max_nodes do
    id = length(nodes)

    label =
      Enum.join(
        Enum.reject([plan["Node Type"], plan["Relation Name"], plan["Index Name"]], &is_nil/1),
        " · "
      )

    details =
      fields(plan, [
        "Total Cost",
        "Plan Rows",
        "Actual Total Time",
        "Actual Rows",
        "Actual Loops",
        "Filter",
        "Index Cond"
      ])

    metrics = %{
      cost: number(plan["Total Cost"]),
      time: number(plan["Actual Total Time"]),
      loops: number(plan["Actual Loops"]),
      rows: number(plan["Plan Rows"])
    }

    nodes = nodes ++ [%{id: id, parent: parent, label: label, details: details, metrics: metrics}]

    Enum.reduce(plan["Plans"] || [], nodes, fn child, acc ->
      postgres_nodes(child, id, acc)
    end)
  end

  defp postgres_nodes(_plan, _parent, nodes), do: nodes

  defp mysql_nodes(key, value, parent, nodes) when length(nodes) <= @max_nodes do
    id = length(nodes)

    label =
      if key == "table" and is_map(value) do
        Enum.join(Enum.reject([value["access_type"], value["table_name"]], &is_nil/1), " · ")
      else
        key |> String.replace("_", " ") |> String.capitalize()
      end

    {details, metrics} = mysql_data(value)

    nodes = nodes ++ [%{id: id, parent: parent, label: label, details: details, metrics: metrics}]
    children = if is_list(value), do: value, else: [value]

    Enum.reduce(children, nodes, fn child, acc ->
      Enum.reduce(@mysql_operations, acc, fn operation, current ->
        if is_map(child) && Map.has_key?(child, operation) do
          mysql_nodes(operation, child[operation], id, current)
        else
          current
        end
      end)
    end)
  end

  defp mysql_nodes(_key, _value, _parent, nodes), do: nodes

  defp mysql_data(value) when is_map(value) do
    cost_info = value["cost_info"] || %{}

    details =
      fields(
        value,
        ~w(access_type key rows_examined_per_scan rows_produced_per_join filtered attached_condition using_filesort using_temporary_table)
      )

    cost = fields(cost_info, ~w(query_cost read_cost eval_cost prefix_cost))

    metrics = %{
      cost: number(cost_info["query_cost"]),
      own_cost: sum_known([number(cost_info["read_cost"]), number(cost_info["eval_cost"])]),
      rows: number(value["rows_examined_per_scan"])
    }

    {Enum.join(Enum.reject([details, cost], &(&1 == "")), " · "), metrics}
  end

  defp mysql_data(_value), do: {"", %{}}

  defp fields(map, keys) do
    keys
    |> Enum.flat_map(fn key -> if is_nil(map[key]), do: [], else: ["#{key}: #{map[key]}"] end)
    |> Enum.join(" · ")
  end

  defp text_nodes(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&String.split(&1, "\n"))
    |> Enum.reduce({[], []}, fn line, {nodes, stack} ->
      case text_node(line) do
        {indent, text} when length(nodes) <= @max_nodes ->
          stack = Enum.drop_while(stack, fn {level, _id} -> level >= indent end)

          parent =
            case stack do
              [{_, id} | _] -> id
              [] -> nil
            end

          id = length(nodes)
          [label | metadata] = String.split(text, ~r/\s+(?=\((?:cost=|actual time=))/, parts: 2)

          node = %{
            id: id,
            parent: parent,
            label: label,
            details: Enum.join(metadata),
            metrics: text_metrics(text)
          }

          {nodes ++ [node], [{indent, id} | stack]}

        _ ->
          {nodes, stack}
      end
    end)
    |> elem(0)
  end

  defp mysql_tabular(rows) do
    rows
    |> Enum.reduce({[], %{}}, fn row, {nodes, blocks} ->
      if length(nodes) > @max_nodes do
        {nodes, blocks}
      else
        row = Map.new(row, fn {key, value} -> {String.downcase(key), value} end)
        block = {row["id"], row["select_type"]}

        {nodes, blocks, parent} =
          case Map.fetch(blocks, block) do
            {:ok, parent} ->
              {nodes, blocks, parent}

            :error ->
              id = length(nodes)
              label = "Query block #{row["id"] || "result"} · #{row["select_type"] || "SELECT"}"

              root = %{
                id: id,
                parent: nil,
                label: label,
                details: "Tables shown in EXPLAIN order",
                metrics: %{}
              }

              {nodes ++ [root], Map.put(blocks, block, id), id}
          end

        node = %{
          id: length(nodes),
          parent: parent,
          label:
            Enum.join(Enum.reject([row["type"], row["table"] || "Result"], &is_nil/1), " · "),
          details: fields(row, ~w(key possible_keys rows filtered extra)),
          metrics: %{rows: number(row["rows"])}
        }

        {nodes ++ [node], blocks}
      end
    end)
    |> elem(0)
  end

  defp text_metrics(text) do
    cost =
      Regex.run(
        ~r/cost=(?:\d+(?:\.\d+)?\.\.)?(\d+(?:\.\d+)?(?:e[+-]?\d+)?)\s+rows=(\d+(?:\.\d+)?(?:e[+-]?\d+)?)/i,
        text
      )

    time =
      Regex.run(
        ~r/actual time=\S+\.\.(\d+(?:\.\d+)?(?:e[+-]?\d+)?)\s+rows=\S+\s+loops=(\d+)/i,
        text
      )

    metrics =
      case cost do
        [_, total, rows] -> %{cost: number(total), rows: number(rows)}
        _ -> %{}
      end

    case time do
      [_, total, loops] ->
        Map.merge(metrics, %{time: number(total), loops: number(loops)})

      _ ->
        if String.contains?(text, "never executed"),
          do: Map.merge(metrics, %{loops: 0}),
          else: metrics
    end
  end

  defp number(value) when is_number(value) and value >= 0, do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> nil
    end
  end

  defp number(_value), do: nil

  defp sum_known(values) do
    case Enum.reject(values, &is_nil/1) do
      [] -> nil
      numbers -> Enum.sum(numbers)
    end
  end

  defp analyze(nodes, type, truncated) do
    children = Enum.group_by(nodes, & &1.parent)
    metric = if truncated, do: nil, else: choose_metric(nodes, children)

    nodes =
      Enum.map(nodes, fn node ->
        Map.merge(node, %{
          score: score(node, metric, Map.get(children, node.id, [])),
          warnings: warnings(node, type)
        })
      end)

    maximum = nodes |> Enum.map(&(&1.score || 0)) |> Enum.max(fn -> 0 end)

    hotspots =
      nodes
      |> Enum.filter(&hotspot_candidate?(&1, maximum, metric))
      |> Enum.sort_by(& &1.score, :desc)
      |> Enum.take(3)
      |> MapSet.new(& &1.id)

    nodes =
      Enum.map(nodes, fn node ->
        Map.merge(node, %{
          hotspot: MapSet.member?(hotspots, node.id),
          relative: if(maximum > 0, do: (node.score || 0) / maximum * 100, else: 0),
          metric: metric
        })
      end)

    %{nodes: nodes, metric: metric}
  end

  defp choose_metric(nodes, children) do
    has_timing = Enum.any?(nodes, &is_number(&1.metrics[:time]))
    metrics = if has_timing, do: [:time, :cost, :rows], else: [:cost, :rows]

    Enum.find(metrics, fn metric ->
      Enum.any?(nodes, fn node ->
        is_number(score(node, metric, Map.get(children, node.id, [])))
      end)
    end)
  end

  defp hotspot_candidate?(node, maximum, :rows),
    do: is_number(node.score) and node.score >= 10_000 and node.score >= maximum / 2

  defp hotspot_candidate?(node, maximum, _metric),
    do: is_number(node.score) and node.score > 0 and node.score >= maximum / 2

  defp score(_node, nil, _children), do: nil
  defp score(%{metrics: %{loops: 0}}, _metric, _children), do: 0
  defp score(node, :rows, _children), do: node.metrics[:rows]

  defp score(node, :cost, _children) when is_number(node.metrics.own_cost),
    do: node.metrics.own_cost

  defp score(node, metric, children) do
    total = total(node, metric)
    child_totals = Enum.map(children, &total(&1, metric))

    if is_number(total) && Enum.all?(child_totals, &is_number/1) do
      max(total - Enum.sum(child_totals), 0)
    end
  end

  defp total(node, :cost), do: node.metrics[:cost] || node.metrics[:own_cost]

  defp total(node, :time) do
    cond do
      node.metrics[:loops] == 0 -> 0
      is_number(node.metrics[:time]) -> node.metrics[:time] * (node.metrics[:loops] || 1)
      true -> nil
    end
  end

  defp warnings(node, :sqlite) do
    text = String.upcase(node.label <> " " <> node.details)

    []
    |> maybe_warning(
      String.starts_with?(text, "SCAN ") && !String.contains?(text, "USING ") &&
        !String.contains?(text, "CONSTANT"),
      "Full scan"
    )
    |> maybe_warning(String.contains?(text, "TEMP B-TREE"), "Temporary B-tree")
  end

  defp warnings(node, :mysql) do
    text = String.upcase(node.label <> " " <> node.details)

    []
    |> maybe_warning(
      String.starts_with?(text, "ALL ·") || String.starts_with?(text, "TABLE SCAN ON "),
      "Full table scan"
    )
    |> maybe_warning(
      String.contains?(text, "USING FILESORT") || String.contains?(text, "USING_FILESORT: TRUE"),
      "Filesort"
    )
    |> maybe_warning(
      String.contains?(text, "USING TEMPORARY") ||
        String.contains?(text, "USING_TEMPORARY_TABLE: TRUE"),
      "Temporary table"
    )
  end

  defp warnings(_node, _type), do: []

  defp maybe_warning(warnings, true, label), do: warnings ++ [label]
  defp maybe_warning(warnings, false, _label), do: warnings

  defp text_node(line) do
    case Regex.run(~r/^(\s*)->\s*(.+)$/, line) do
      [_, indent, text] ->
        {String.length(indent), text}

      _ ->
        if String.contains?(line, "(cost=") do
          {String.length(line) - String.length(String.trim_leading(line)), String.trim(line)}
        end
    end
  end
end
