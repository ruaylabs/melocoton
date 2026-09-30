defmodule MelocotonWeb.AiUsageReportComponent do
  use MelocotonWeb, :live_component

  alias Melocoton.Databases

  @empty_filters %{
    "group_id" => "",
    "database_id" => "",
    "provider" => "",
    "model" => "",
    "from" => "",
    "to" => ""
  }
  @metrics ~w(messages input_tokens output_tokens total_tokens input_cost output_cost total_cost unknown_tokens)a

  @impl true
  def mount(socket) do
    socket
    |> assign(
      loaded: false,
      groups: [],
      databases: [],
      providers: [],
      models: [],
      form: to_form(@empty_filters, as: :filters),
      error: nil
    )
    |> assign_report([])
    |> ok()
  end

  @impl true
  def update(%{action: :open}, socket) do
    rows = Databases.ai_usage_report()

    socket =
      socket
      |> assign(
        loaded: true,
        groups: Enum.map(Databases.list_groups(), &{&1.name, &1.id}),
        databases: Enum.map(Databases.list_databases(), &{&1.name, &1.id}),
        providers: options(rows, :provider),
        models: options(rows, :model),
        form: to_form(@empty_filters, as: :filters),
        error: nil
      )
      |> assign_report(rows)

    socket |> push_event("open-ai-usage-modal", %{}) |> ok()
  end

  def update(assigns, socket), do: socket |> assign(assigns) |> ok()

  @impl true
  def handle_event("filter", %{"filters" => params}, socket) do
    params = Map.merge(@empty_filters, Map.take(params, Map.keys(@empty_filters)))
    socket = assign(socket, form: to_form(params, as: :filters))

    case parse_filters(params) do
      {:ok, filters} ->
        {:noreply,
         socket |> assign(error: nil) |> assign_report(Databases.ai_usage_report(filters))}

      :error ->
        {:noreply, assign(socket, error: "Enter a valid date range and filter selection.")}
    end
  end

  defp parse_filters(params) do
    with {:ok, group_id} <- parse_id(params["group_id"]),
         {:ok, database_id} <- parse_id(params["database_id"]),
         {:ok, from} <- parse_date(params["from"]),
         {:ok, to} <- parse_date(params["to"]),
         true <- is_nil(from) or is_nil(to) or Date.compare(from, to) != :gt do
      {:ok,
       [
         group_id: group_id,
         database_id: database_id,
         provider: params["provider"],
         model: params["model"],
         from: from,
         to: to
       ]}
    else
      _ -> :error
    end
  end

  defp parse_id(""), do: {:ok, nil}

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> {:ok, id}
      _ -> :error
    end
  end

  defp parse_date(""), do: {:ok, nil}
  defp parse_date(value), do: Date.from_iso8601(value)

  defp options(rows, key) do
    rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()
  end

  defp assign_report(socket, rows) do
    totals =
      Map.new(@metrics, fn key ->
        {key, Enum.reduce(rows, nil, fn row, total -> add_metric(total, row[key]) end)}
      end)

    assign(socket, rows: rows, totals: totals)
  end

  defp add_metric(nil, value), do: value
  defp add_metric(value, nil), do: value
  defp add_metric(%Decimal{} = total, value), do: Decimal.add(total, value)
  defp add_metric(total, value), do: total + value

  defp format_cost(nil), do: "Unknown"
  defp format_cost(cost), do: "$" <> Decimal.to_string(Decimal.round(cost, 6), :normal)
end
