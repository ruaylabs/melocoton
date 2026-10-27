defmodule MelocotonWeb.SqlLive.QueryPlanComponent do
  use Phoenix.Component

  attr :plan, :map, required: true

  def chart(assigns) do
    children = Enum.group_by(assigns.plan.nodes, & &1.parent)
    assigns = assign(assigns, children: children, roots: Map.get(children, nil, []))

    ~H"""
    <section id="query-plan-chart" class="p-4 text-xs" aria-label="Query execution plan">
      <p :if={@plan.truncated} class="mb-3" style="color: var(--text-secondary);">
        Partial plan: only the first returned steps are shown. See Results for the raw output.
      </p>
      <p id="query-plan-legend" class="mb-3" style="color: var(--text-tertiary);">
        {legend(@plan)}
      </p>
      <.nodes nodes={@roots} children={@children} />
    </section>
    """
  end

  defp legend(%{truncated: true}),
    do: "Partial plans are not ranked. Badges flag potential work, not measured expense."

  defp legend(%{metric: :time}),
    do:
      "Relative hotspots use approximate self time (ms × loops), minus child time. Parallel or asynchronous work can overlap; this is not wall-clock attribution."

  defp legend(%{metric: :cost}),
    do:
      "Relative hotspots use estimated self cost, minus child costs where available. Optimizer cost units are not milliseconds."

  defp legend(%{metric: :rows}),
    do:
      "This format has no numeric costs or timings. Row estimates are not execution time; scan and sort badges flag potential work."

  defp legend(_plan),
    do:
      "This format has no numeric costs or timings. Scan and sort badges flag potential work, not measured expense."

  defp metric_text(node) do
    value =
      :erlang.float_to_binary(node.score * 1.0, decimals: 3)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    case node.metric do
      :time -> "#{value} ms · approximate self time"
      :cost -> "#{value} cost units · estimated self cost"
      :rows -> "#{value} estimated rows"
    end
  end

  attr :nodes, :list, required: true
  attr :children, :map, required: true
  attr :nested, :boolean, default: false

  defp nodes(assigns) do
    ~H"""
    <ul class="space-y-3">
      <li :for={node <- @nodes} class="relative">
        <span
          :if={@nested}
          class="absolute -left-4 top-4 w-4 border-t"
          style="border-color: var(--border-medium);"
          aria-hidden="true"
        />
        <div
          class="rounded border px-3 py-2 max-w-2xl break-words"
          data-hotspot={to_string(node[:hotspot] || false)}
          style={
            if node[:hotspot] do
              "background: rgba(245, 158, 11, 0.08); border-color: #d97706;"
            else
              "background: var(--bg-primary); border-color: var(--border-medium);"
            end
          }
        >
          <div class="flex flex-wrap items-center gap-2">
            <p class="font-medium" style="color: var(--text-primary);">{node.label}</p>
            <span
              :if={node[:hotspot]}
              class="rounded px-1.5 py-0.5 text-[10px] font-medium bg-amber-500/15 text-amber-800 dark:text-amber-300"
            >
              {if node[:metric] == :rows, do: "High row estimate", else: "Relative hotspot"}
            </span>
            <span
              :for={warning <- node[:warnings] || []}
              class="rounded px-1.5 py-0.5 text-[10px] bg-amber-500/10 text-amber-800 dark:text-amber-300"
            >
              {warning}
            </span>
          </div>
          <div :if={is_number(node[:score])} class="mt-2">
            <p class="text-[10px]" style="color: var(--text-secondary);">
              {metric_text(node)} · {round(node.relative)}% of largest operator
            </p>
            <div class="h-1 mt-1 rounded bg-black/5 dark:bg-white/10" aria-hidden="true">
              <div
                class="h-1 rounded"
                style={"width: #{node.relative}%; background: #{if node[:hotspot], do: "#d97706", else: "var(--text-tertiary)"};"}
              />
            </div>
          </div>
          <p
            :if={node.details != ""}
            class="mt-1 font-mono text-[10px]"
            style="color: var(--text-tertiary);"
          >
            {node.details}
          </p>
        </div>
        <div
          :if={Map.has_key?(@children, node.id)}
          class="ml-4 mt-2 border-l pl-4"
          style="border-color: var(--border-medium);"
        >
          <.nodes nodes={Map.fetch!(@children, node.id)} children={@children} nested />
        </div>
      </li>
    </ul>
    """
  end
end
