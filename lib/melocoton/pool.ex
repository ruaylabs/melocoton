defmodule Melocoton.Pool do
  use GenServer
  alias Melocoton.Connection

  # Check for dead connections every 60 seconds
  @check_interval_ms :timer.seconds(60)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    schedule_health_check()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:get_conn, database}, _from, state) do
    case Map.get(state, database.id) do
      nil ->
        connect(database, state)

      %Connection{pid: pid} = conn ->
        if Process.alive?(pid) do
          {:reply, conn, state}
        else
          connect(database, Map.delete(state, database.id))
        end
    end
  end

  def handle_call({:release, database_id}, _from, state) do
    case Map.pop(state, database_id) do
      {nil, state} ->
        {:reply, :ok, state}

      {%Connection{pid: pid}, state} ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1_000)
          catch
            :exit, _ -> :ok
          end
        end

        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:health_check, state) do
    new_state =
      state
      |> Enum.filter(fn {_id, %Connection{pid: pid}} -> Process.alive?(pid) end)
      |> Map.new()

    schedule_health_check()
    {:noreply, new_state}
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @check_interval_ms)
  end

  defp connect(database, state) do
    case start_connection(database) do
      {:ok, pid} ->
        conn = %Connection{pid: pid, type: database.type}
        {:reply, conn, Map.put(state, database.id, conn)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def get_repo(database), do: GenServer.call(__MODULE__, {:get_conn, database})

  @doc """
  Stops the cached connection for `database_id` and removes it from the pool.

  Called when a LiveView terminates so that DBConnection pool workers stop
  retrying against a backend the user no longer cares about, instead of
  spamming logs with reconnection attempts.
  """
  def release(database_id), do: GenServer.call(__MODULE__, {:release, database_id})

  defp start_connection(%{type: :postgres, url: url}) do
    opts = Ecto.Repo.Supervisor.parse_url(url)
    Postgrex.start_link(opts ++ [pool_size: 5, ssl_opts: [verify: :verify_none]])
  end

  defp start_connection(%{type: :mysql, url: url}) do
    uri = URI.parse(url)
    {user, password} = parse_userinfo(uri.userinfo)

    MyXQL.start_link(
      hostname: uri.host || "localhost",
      port: uri.port || 3306,
      username: user,
      password: password,
      database: String.trim_leading(uri.path || "", "/"),
      pool_size: 5,
      after_connect: fn conn -> MyXQL.query!(conn, "SET sql_mode = 'ANSI_QUOTES'", []) end
    )
  end

  defp start_connection(%{type: :sqlite, url: url}) do
    DBConnection.start_link(Exqlite.Connection, database: url, pool_size: 1)
  end

  defp parse_userinfo(nil), do: {"", ""}

  defp parse_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {URI.decode(user), URI.decode(pass)}
      [user] -> {URI.decode(user), ""}
    end
  end
end
