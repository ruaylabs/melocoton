defmodule MelocotonWeb.SQLLive.Run do
  use MelocotonWeb, :live_view

  require Logger
  alias Melocoton.{DatabaseClient, Databases, Pool, Settings, TransactionSession}
  import MelocotonWeb.SqlLive.SidebarComponents, only: [section: 1]
  import MelocotonWeb.SqlLive.QueryPlanComponent, only: [chart: 1]

  @max_rows 1_000

  @impl Phoenix.LiveView
  def mount(%{"database_id" => database_id}, _session, socket) do
    Melocoton.Settings.apply_api_keys_to_runtime()

    database = Databases.get_database!(database_id)
    Task.start(fn -> Databases.touch_last_connected(database) end)
    Phoenix.PubSub.subscribe(Melocoton.PubSub, Databases.ai_chat_topic(database_id))
    conn = Pool.get_repo(database)
    # we need to get pid here because the call to get_tables/2 will be
    # made in another process so we won't be able to get the correct
    # PID
    liveview_pid = self()

    tabs =
      case database.sessions do
        [] ->
          session = create_session(database, "#1")
          [%{type: :query, session: session}]

        sessions ->
          Enum.map(sessions, &%{type: :query, session: &1})
      end

    socket
    |> assign(:filter_results_form, to_form(%{"term" => ""}))
    |> assign(:filter_term, "")
    |> assign(:search_form, to_form(%{"term" => ""}))
    |> assign(:search_term, "")
    |> assign(:conn, conn)
    |> assign_async(:tables, fn -> get_tables(conn, liveview_pid) end)
    |> assign_async(:indexes, fn -> get_indexes(conn) end)
    |> assign_async(:functions, fn -> get_functions(conn) end)
    |> assign_async(:triggers, fn -> get_triggers(conn) end)
    |> assign(:database, database)
    |> assign(:tabs, tabs)
    |> assign(:active_tab_index, 0)
    |> assign(:filter_result, empty_result())
    |> assign(:result, empty_result())
    |> assign(:error_message, nil)
    |> assign(:page_title, database.name)
    |> assign(:running_transaction?, false)
    |> assign(:transaction_session, nil)
    |> assign(:query_time, 0)
    |> assign(:last_query, nil)
    |> assign(:result_truncated, false)
    |> assign(:active_result_tab, :results)
    |> assign(:query_plan, nil)
    |> assign(:query_history, [])
    |> assign(:running_query, false)
    |> assign(:renaming_tab_index, nil)
    |> assign(:ai_panel_open, project_setting(database.id, "ai_panel_open") == "true")
    |> assign(
      :sidebar_width,
      parse_panel_width(project_setting(database.id, "sidebar_width"), 18)
    )
    |> assign(
      :ai_panel_width,
      parse_panel_width(project_setting(database.id, "ai_panel_width"), 22)
    )
    |> push_font_size()
    |> ok()
  end

  @impl true
  def terminate(_reason, socket) do
    case socket.assigns[:database] do
      %{id: id} -> Pool.release(id)
      _ -> :ok
    end
  end

  defp empty_result do
    %{cols: [], rows: [], num_rows: 0}
  end

  defp push_font_size(socket) do
    if connected?(socket) do
      font_size = Settings.get("font_size") || "md"
      push_event(socket, "set-font-size", %{size: font_size})
    else
      socket
    end
  end

  defp active_tab(socket), do: Enum.at(socket.assigns.tabs, socket.assigns.active_tab_index)

  defp current_session(socket) do
    case active_tab(socket) do
      %{type: :query, session: session} -> session
      _ -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"session" => params}, socket) do
    case current_session(socket) do
      nil ->
        noreply(socket)

      session ->
        {:ok, updated_session} = Databases.update_session(session, params)

        tabs =
          List.update_at(socket.assigns.tabs, socket.assigns.active_tab_index, fn tab ->
            %{tab | session: updated_session}
          end)

        socket
        |> assign(:tabs, tabs)
        |> noreply()
    end
  end

  def handle_event("validate-search", %{"term" => term}, socket) do
    socket
    |> assign(:search_term, term)
    |> noreply()
  end

  def handle_event("validate-filter-results", %{"term" => term}, socket) do
    cols = Enum.map(socket.assigns.result.cols, &to_string/1)

    rows =
      socket.assigns.result.rows
      |> Enum.filter(fn row ->
        row
        |> Map.take(cols)
        |> Map.values()
        |> Enum.map_join(" ", fn v ->
          str = if is_binary(v), do: v, else: inspect(v, structs: false)
          str |> String.downcase()
        end)
        |> String.contains?(String.downcase(term))
      end)

    socket
    |> assign(:filter_result, Map.put(socket.assigns.result, :rows, rows))
    |> assign(:filter_term, term)
    |> noreply()
  end

  def handle_event("next-session", _params, socket), do: cycle_tab(socket, 1)
  def handle_event("prev-session", _params, socket), do: cycle_tab(socket, -1)

  def handle_event(
        "set-function-explorer",
        %{"id" => id, "name" => name, "kind" => kind},
        socket
      ) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.type == :function and &1.function_id == id)) do
      nil ->
        new_tab = %{type: :function, function_id: id, function_name: name, function_kind: kind}
        tabs = tabs ++ [new_tab]

        socket
        |> assign(:tabs, tabs)
        |> assign(:active_tab_index, length(tabs) - 1)
        |> noreply()

      existing_index ->
        socket
        |> assign(:active_tab_index, existing_index)
        |> noreply()
    end
  end

  def handle_event(
        "set-trigger-explorer",
        %{"id" => id, "name" => name, "table" => table},
        socket
      ) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.type == :trigger and &1.trigger_id == id)) do
      nil ->
        new_tab = %{type: :trigger, trigger_id: id, trigger_name: name, trigger_table: table}
        tabs = tabs ++ [new_tab]

        socket
        |> assign(:tabs, tabs)
        |> assign(:active_tab_index, length(tabs) - 1)
        |> noreply()

      existing_index ->
        socket
        |> assign(:active_tab_index, existing_index)
        |> noreply()
    end
  end

  def handle_event(
        "set-index-explorer",
        %{"name" => name, "table" => table},
        socket
      ) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.type == :index and &1.index_name == name)) do
      nil ->
        new_tab = %{type: :index, index_name: name, index_table: table}
        tabs = tabs ++ [new_tab]

        socket
        |> assign(:tabs, tabs)
        |> assign(:active_tab_index, length(tabs) - 1)
        |> noreply()

      existing_index ->
        socket
        |> assign(:active_tab_index, existing_index)
        |> noreply()
    end
  end

  def handle_event("set-table-explorer", %{"table" => ""}, socket), do: noreply(socket)

  def handle_event("set-table-explorer", %{"table" => table_name}, socket) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.type == :table and &1.table_name == table_name)) do
      nil ->
        new_tab = %{type: :table, table_name: table_name}
        tabs = tabs ++ [new_tab]

        socket
        |> assign(:tabs, tabs)
        |> assign(:active_tab_index, length(tabs) - 1)
        |> noreply()

      existing_index ->
        socket
        |> assign(:active_tab_index, existing_index)
        |> noreply()
    end
  end

  def handle_event("activate-tab", %{"index" => index}, socket) do
    index = String.to_integer(index)

    socket
    |> activate_tab(index)
    |> noreply()
  end

  def handle_event("close-tab", %{"index" => index}, socket) do
    index = String.to_integer(index)
    tabs = socket.assigns.tabs
    tab = Enum.at(tabs, index)

    if tab.type == :query && Enum.count(tabs, &(&1.type == :query)) <= 1 do
      noreply(socket)
    else
      tabs = List.delete_at(tabs, index)

      active_index =
        cond do
          index < socket.assigns.active_tab_index -> socket.assigns.active_tab_index - 1
          index == socket.assigns.active_tab_index -> min(index, length(tabs) - 1)
          true -> socket.assigns.active_tab_index
        end

      socket
      |> assign(:tabs, tabs)
      |> activate_tab(active_index)
      |> noreply()
    end
  end

  @impl Phoenix.LiveView
  def handle_event("new-session", _params, socket) do
    query_count = Enum.count(socket.assigns.tabs, &(&1.type == :query))
    name = "query_#{query_count + 1}.sql"
    session = create_session(socket.assigns.database, name)
    updated_database = Databases.get_database!(socket.assigns.database.id)

    new_tab = %{type: :query, session: session}
    tabs = socket.assigns.tabs ++ [new_tab]

    socket
    |> assign(:database, updated_database)
    |> assign(:tabs, tabs)
    |> activate_tab(length(tabs) - 1)
    |> noreply()
  end

  def handle_event("start-rename-tab", %{"index" => index}, socket) do
    socket
    |> assign(:renaming_tab_index, String.to_integer(index))
    |> noreply()
  end

  def handle_event("commit-rename-tab", %{"index" => index, "value" => name}, socket) do
    index = String.to_integer(index)
    name = String.trim(name)

    socket =
      with ^index <- socket.assigns.renaming_tab_index,
           %{type: :query} = tab <- Enum.at(socket.assigns.tabs, index),
           {:ok, updated} <- Databases.update_session(tab.session, %{name: name}) do
        updated_tabs = List.replace_at(socket.assigns.tabs, index, %{tab | session: updated})
        assign(socket, :tabs, updated_tabs)
      else
        _ -> socket
      end

    socket |> close_rename() |> noreply()
  end

  def handle_event(
        "keydown-rename-tab",
        %{"key" => "Enter", "value" => name, "index" => index},
        socket
      ) do
    handle_event("commit-rename-tab", %{"index" => index, "value" => name}, socket)
  end

  def handle_event("keydown-rename-tab", %{"key" => "Escape"}, socket) do
    socket |> close_rename() |> noreply()
  end

  def handle_event("keydown-rename-tab", _params, socket), do: noreply(socket)

  def handle_event("run-query", %{"query" => query}, socket) do
    Logger.info("Running query #{query}")
    normalized = query |> String.trim() |> String.downcase()

    if socket.assigns.database.group.read_only and write_query?(normalized) do
      socket
      |> assign(:error_message, "Read-only mode: write operations are blocked for this group.")
      |> noreply()
    else
      dispatch_query(socket, query, normalized)
    end
  end

  def handle_event("reload-objects", _params, socket) do
    conn = socket.assigns.conn
    liveview_pid = self()

    socket
    |> assign_async(:tables, fn -> get_tables(conn, liveview_pid) end)
    |> assign_async(:indexes, fn -> get_indexes(conn) end)
    |> assign_async(:functions, fn -> get_functions(conn) end)
    |> assign_async(:triggers, fn -> get_triggers(conn) end)
    |> noreply()
  end

  def handle_event("do-nothing", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("save-query", _params, socket) do
    case current_session(socket) do
      nil ->
        noreply(socket)

      session ->
        token =
          Melocoton.ExportStore.put(%{
            query: session.query,
            database_name: socket.assigns.database.name
          })

        socket
        |> push_event("open-url", %{url: ~p"/export/sql/#{token}"})
        |> noreply()
    end
  end

  def handle_event("export", %{"format" => format}, socket) do
    token =
      Melocoton.ExportStore.put(%{
        result: socket.assigns.result,
        database_name: socket.assigns.database.name
      })

    socket
    |> push_event("open-url", %{url: ~p"/export/#{format}/#{token}"})
    |> noreply()
  end

  @impl true
  def handle_event("toggle-ai-panel", _params, socket) do
    open = !socket.assigns.ai_panel_open
    save_project_setting(socket.assigns.database.id, "ai_panel_open", to_string(open))

    socket
    |> assign(:ai_panel_open, open)
    |> then(fn s ->
      if open, do: push_event(s, "focus-ai-chat", %{}), else: push_event(s, "refocus-editor", %{})
    end)
    |> noreply()
  end

  def handle_event("explain-with-ai", _params, socket) do
    socket |> explain_with_ai() |> noreply()
  end

  def handle_event("switch-result-tab", %{"tab" => tab}, socket) do
    tab =
      case tab do
        "history" -> :history
        "plan" when not is_nil(socket.assigns.query_plan) -> :plan
        _ -> :results
      end

    if tab == :history do
      history = Databases.list_query_history(socket.assigns.database.id)
      assign(socket, :query_history, history)
    else
      socket
    end
    |> assign(:active_result_tab, tab)
    |> noreply()
  end

  def handle_event("load-from-history", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.query_history, &(to_string(&1.id) == id)) do
      nil ->
        noreply(socket)

      entry ->
        socket
        |> assign(:active_result_tab, :results)
        |> push_event("load-query", %{query: entry.query})
        |> noreply()
    end
  end

  def handle_event("delete-history-entry", %{"id" => id}, socket) do
    Databases.delete_query_history_entry(id)
    history = Databases.list_query_history(socket.assigns.database.id)

    socket
    |> assign(:query_history, history)
    |> noreply()
  end

  def handle_event("clear-history", _params, socket) do
    Databases.clear_query_history(socket.assigns.database.id)

    socket
    |> assign(:query_history, [])
    |> noreply()
  end

  def handle_event("save-panel-widths", %{"sidebar" => sidebar, "ai" => ai}, socket) do
    db_id = socket.assigns.database.id
    save_project_setting(db_id, "sidebar_width", to_string(sidebar))
    save_project_setting(db_id, "ai_panel_width", to_string(ai))

    socket
    |> assign(:sidebar_width, sidebar)
    |> assign(:ai_panel_width, ai)
    |> noreply()
  end

  @impl true
  def handle_info({MelocotonWeb.SqlLive.TableExplorerComponent, {:flash, kind, msg}}, socket) do
    socket
    |> put_flash(kind, msg)
    |> noreply()
  end

  @impl true
  def handle_info({MelocotonWeb.SqlLive.AiChatComponent, {:insert_sql, sql}}, socket) do
    socket
    |> push_event("append-query", %{query: sql})
    |> noreply()
  end

  @impl true
  def handle_info({MelocotonWeb.SqlLive.AiChatComponent, {:run_sql, sql}}, socket) do
    socket = push_event(socket, "append-query", %{query: sql})
    handle_event("run-query", %{"query" => sql}, socket)
  end

  @impl true
  def handle_info({MelocotonWeb.SqlLive.AiChatComponent, :close_ai_panel}, socket) do
    save_project_setting(socket.assigns.database.id, "ai_panel_open", "false")

    socket
    |> assign(:ai_panel_open, false)
    |> push_event("refocus-editor", %{})
    |> noreply()
  end

  @impl true
  def handle_info({:ai_chat, event, data}, socket)
      when event in [:assistant_message_saved, :ai_error] do
    send_update(MelocotonWeb.SqlLive.AiChatComponent,
      id: "ai-chat",
      ai_chat_pubsub: {event, data}
    )

    noreply(socket)
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, socket)
      when pid == socket.assigns.transaction_session and not is_nil(pid) do
    socket |> clear_transaction() |> noreply()
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    noreply(socket)
  end

  @impl true
  def handle_info(:explain_with_ai, socket) do
    socket |> explain_with_ai() |> noreply()
  end

  @impl true
  def handle_info({:send_schema, schema}, socket) do
    # prepare tables information to fit
    schema_for_editor =
      schema
      |> Enum.map(fn %{name: name, cols: cols} ->
        {name, Enum.map(cols, & &1.name)}
      end)
      |> Enum.into(%{})

    socket
    |> push_event("load-schema", %{schema: schema_for_editor, type: socket.assigns.database.type})
    |> noreply()
  end

  @impl true
  def handle_info({:execute_query, query}, socket) do
    result_socket =
      if socket.assigns.running_transaction? do
        handle_transaction_query(socket, query)
      else
        handle_regular_query(socket, query)
      end

    result_socket
    |> assign(:running_query, false)
    |> noreply()
  end

  defp close_rename(socket) do
    socket
    |> assign(:renaming_tab_index, nil)
    |> push_event("refocus-editor", %{})
  end

  defp dispatch_query(socket, query, normalized) do
    cond do
      normalized =~ ~r/^begin\b/ ->
        handle_begin(socket)

      normalized =~ ~r/^commit\b/ and socket.assigns.running_transaction? ->
        handle_commit(socket)

      normalized =~ ~r/^rollback\b/ and socket.assigns.running_transaction? ->
        handle_rollback(socket)

      true ->
        # Defer execution so the loading state renders before the query blocks
        send(self(), {:execute_query, query})

        socket
        |> assign(:running_query, true)
        |> noreply()
    end
  end

  defp handle_begin(socket) do
    case TransactionSession.start(socket.assigns.conn, self()) do
      {:ok, session_pid} ->
        Process.monitor(session_pid)

        socket
        |> assign(:running_transaction?, true)
        |> assign(:transaction_session, session_pid)
        |> assign(:error_message, nil)
        |> noreply()

      {:error, reason} ->
        socket
        |> assign(:error_message, "Failed to start transaction: #{inspect(reason)}")
        |> noreply()
    end
  end

  defp handle_commit(socket) do
    TransactionSession.commit(socket.assigns.transaction_session)
    socket |> clear_transaction() |> noreply()
  end

  defp handle_rollback(socket) do
    TransactionSession.rollback(socket.assigns.transaction_session)
    socket |> clear_transaction() |> noreply()
  end

  defp handle_transaction_query(socket, query) do
    init_time = System.monotonic_time(:nanosecond)
    result = TransactionSession.query(socket.assigns.transaction_session, query)
    end_time = System.monotonic_time(:nanosecond)
    total_time = System.convert_time_unit(end_time - init_time, :nanosecond, :millisecond)

    case result do
      {:ok, raw_result} ->
        response = DatabaseClient.handle_response(raw_result)
        {response, truncated} = DatabaseClient.maybe_truncate(response, @max_rows)
        apply_query_result(socket, query, {:ok, response, total_time, truncated})

      {:error, reason} ->
        apply_query_result(
          socket,
          query,
          {:error, DatabaseClient.translate_query_error(reason), total_time}
        )
    end
  end

  defp handle_regular_query(socket, query) do
    case DatabaseClient.query(socket.assigns.conn, query, %{}, max_rows: @max_rows) do
      {:ok, result, %{total_time: total_time, truncated: truncated}} ->
        apply_query_result(socket, query, {:ok, result, total_time, truncated})

      {:error, reason} ->
        apply_query_result(socket, query, {:error, reason, 0})
    end
  end

  defp apply_query_result(socket, query, {:ok, result, total_time, truncated}) do
    record_query_history(socket.assigns.database.id, query, :success, total_time, result.num_rows)

    plan =
      Melocoton.QueryPlan.from_result(query, result, socket.assigns.database.type,
        truncated: truncated
      )

    tab =
      cond do
        plan -> :plan
        socket.assigns.active_result_tab == :plan -> :results
        true -> socket.assigns.active_result_tab
      end

    socket
    |> assign(result: result, query_plan: plan, active_result_tab: tab)
    |> assign(query_time: total_time)
    |> assign(last_query: query)
    |> assign(:error_message, nil)
    |> assign(:result_truncated, truncated)
    |> maybe_refresh_history()
  end

  defp apply_query_result(socket, query, {:error, reason, total_time}) do
    record_query_history(socket.assigns.database.id, query, :error, total_time, 0, reason)

    socket
    |> assign(:query_plan, nil)
    |> assign(:active_result_tab, :results)
    |> assign(:error_message, reason)
    |> maybe_refresh_history()
  end

  defp create_session(database, name) do
    {:ok, session} = Databases.create_session(%{database_id: database.id, query: "", name: name})
    session
  end

  # receive the liveview of the PID so we can notify once the tables
  # information is computed
  defp get_tables(conn, liveview_pid) do
    case DatabaseClient.get_tables(conn) do
      {:ok, tables} ->
        send(liveview_pid, {:send_schema, tables})
        {:ok, %{tables: tables}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_indexes(conn) do
    case DatabaseClient.get_indexes(conn) do
      {:ok, indexes} -> {:ok, %{indexes: indexes}}
      {:error, error} -> {:error, error}
    end
  end

  defp get_functions(conn) do
    case DatabaseClient.get_functions(conn) do
      {:ok, functions} -> {:ok, %{functions: functions}}
      {:error, error} -> {:error, error}
    end
  end

  defp get_triggers(conn) do
    case DatabaseClient.get_triggers(conn) do
      {:ok, triggers} -> {:ok, %{triggers: triggers}}
      {:error, error} -> {:error, error}
    end
  end

  defp explain_with_ai(socket) do
    result = socket.assigns.result
    query = socket.assigns.last_query

    explain_output =
      Enum.map_join(result.rows, "\n", fn row ->
        row |> Map.values() |> Enum.map_join("\t", &to_string/1)
      end)

    prompt = """
    Analyze the following query execution plan and provide:
    1. A summary of what the query does
    2. Key performance observations (sequential scans, index usage, cost, rows)
    3. Specific optimization suggestions if any

    **Query:**
    ```sql
    #{query}
    ```

    **EXPLAIN ANALYZE output:**
    ```
    #{explain_output}
    ```
    """

    socket =
      if socket.assigns.ai_panel_open do
        socket
      else
        save_project_setting(socket.assigns.database.id, "ai_panel_open", "true")
        assign(socket, :ai_panel_open, true)
      end

    send_update(MelocotonWeb.SqlLive.AiChatComponent, id: "ai-chat", send_message: prompt)

    socket
  end

  defp explain_query?(query), do: Melocoton.QueryPlan.explain?(query)

  defp write_query?(normalized) do
    Regex.match?(~r/^(insert|update|delete|drop|alter|create|truncate|replace)\b/, normalized)
  end

  defp activate_tab(socket, index) do
    socket.assigns.tabs
    |> Enum.at(index)
    |> case do
      %{type: :query, session: session} ->
        push_event(socket, "load-query", %{"query" => session.query})

      _ ->
        socket
    end
    |> assign(:active_tab_index, index)
  end

  defp clear_transaction(socket) do
    socket
    |> assign(:running_transaction?, false)
    |> assign(:transaction_session, nil)
    |> assign(:error_message, nil)
  end

  defp cycle_tab(socket, direction) do
    count = length(socket.assigns.tabs)
    new_index = rem(socket.assigns.active_tab_index + direction + count, count)

    socket
    |> activate_tab(new_index)
    |> noreply()
  end

  defp parse_panel_width(nil, default), do: default

  defp parse_panel_width(value, default) do
    case Float.parse(value) do
      {width, _} when width >= 10 and width <= 50 -> width
      _ -> default
    end
  end

  defp project_setting(database_id, key) do
    Melocoton.Settings.get("project:#{database_id}:#{key}")
  end

  defp save_project_setting(database_id, key, value) do
    Melocoton.Settings.set("project:#{database_id}:#{key}", value)
  end

  defp record_query_history(db_id, query, status, execution_time, row_count, error_message \\ nil) do
    Task.start(fn ->
      Databases.record_query(%{
        query: query,
        database_id: db_id,
        status: status,
        execution_time: execution_time,
        row_count: row_count,
        error_message: error_message,
        executed_at: DateTime.utc_now()
      })
    end)
  end

  defp maybe_refresh_history(socket) do
    if socket.assigns.active_result_tab == :history do
      assign(socket, :query_history, Databases.list_query_history(socket.assigns.database.id))
    else
      socket
    end
  end

  for {color, types} <- [
        {"var(--syntax-number)", ~w(int2 int4 int8 float4 float8 numeric decimal serial bigserial
           smallserial integer real double smallint bigint tinyint mediumint)},
        {"var(--syntax-table)", ~w(text varchar char bpchar name citext character clob
           tinytext mediumtext longtext)},
        {"var(--syntax-keyword)",
         ~w(timestamp timestamptz date time timetz interval datetime year)},
        {"var(--syntax-string)", ~w(json jsonb)},
        {"var(--text-tertiary)", ~w(bytea blob binary varbinary tinyblob mediumblob longblob)},
        {"#22c55e", ~w(bool boolean)},
        {"var(--syntax-comment)", ~w(uuid)}
      ],
      type <- types do
    defp do_type_color(unquote(type)), do: unquote(color)
  end

  defp do_type_color("_" <> _), do: "var(--syntax-string)"
  defp do_type_color(_), do: "var(--text-tertiary)"

  defp type_color(type) do
    type |> String.downcase() |> String.replace(~r/\(.*\)/, "") |> do_type_color()
  end
end
