defmodule Melocoton.PoolTest do
  use Melocoton.DataCase

  alias Melocoton.Connection

  describe "postgres connections" do
    @tag :container
    test "connects with raw and encoded at signs in the password" do
      password = "sec@ret"

      config =
        Testcontainers.PostgresContainer.new()
        |> Testcontainers.PostgresContainer.with_password(password)

      {:ok, container} = Testcontainers.start_container(config)
      params = Testcontainers.PostgresContainer.connection_parameters(container)
      ids = for _ <- 1..2, do: -System.unique_integer([:positive])

      on_exit(fn ->
        Enum.each(ids, &Melocoton.Pool.release/1)
        Testcontainers.stop_container(container.container_id)
      end)

      encoded_password = URI.encode(password, &URI.char_unreserved?/1)

      for {url_password, id} <- Enum.zip([password, encoded_password], ids) do
        database = %{
          id: id,
          type: :postgres,
          url:
            "postgres://#{params[:username]}:#{url_password}@#{params[:hostname]}:#{params[:port]}/#{params[:database]}"
        }

        assert %Connection{pid: pid, type: :postgres} = Melocoton.Pool.get_repo(database)
        assert Process.alive?(pid)
        assert {:ok, %Postgrex.Result{rows: [[1]]}} = Postgrex.query(pid, "SELECT 1", [])
        assert Process.alive?(Process.whereis(Melocoton.Pool))
      end
    end
  end

  describe "health check" do
    test "evicts dead connections from pool state" do
      # Spawn a process and immediately kill it to simulate a dead connection
      dead_pid = spawn(fn -> :ok end)
      # Ensure the process is dead
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      alive_pid = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        1 => %Connection{pid: dead_pid, type: :sqlite},
        2 => %Connection{pid: alive_pid, type: :sqlite}
      }

      :sys.replace_state(Melocoton.Pool, fn _ -> state end)

      # Trigger health check
      send(Melocoton.Pool, :health_check)

      # Give GenServer time to process the message
      Process.sleep(50)

      new_state = :sys.get_state(Melocoton.Pool)

      refute Map.has_key?(new_state, 1)
      assert Map.has_key?(new_state, 2)
      assert %Connection{pid: ^alive_pid} = new_state[2]

      Process.exit(alive_pid, :kill)
    end

    test "keeps all connections when all are alive" do
      pid1 = spawn(fn -> Process.sleep(:infinity) end)
      pid2 = spawn(fn -> Process.sleep(:infinity) end)

      state = %{
        1 => %Connection{pid: pid1, type: :sqlite},
        2 => %Connection{pid: pid2, type: :postgres}
      }

      :sys.replace_state(Melocoton.Pool, fn _ -> state end)

      send(Melocoton.Pool, :health_check)
      Process.sleep(50)

      new_state = :sys.get_state(Melocoton.Pool)
      assert map_size(new_state) == 2

      Process.exit(pid1, :kill)
      Process.exit(pid2, :kill)
    end

    test "handles empty state" do
      :sys.replace_state(Melocoton.Pool, fn _ -> %{} end)

      send(Melocoton.Pool, :health_check)
      Process.sleep(50)

      assert :sys.get_state(Melocoton.Pool) == %{}
    end
  end

  describe "release/1" do
    setup do
      on_exit(fn -> :sys.replace_state(Melocoton.Pool, fn _ -> %{} end) end)
      :ok
    end

    test "stops the cached connection and removes it from state" do
      {:ok, pid} = Agent.start(fn -> :ok end)

      :sys.replace_state(Melocoton.Pool, fn _ ->
        %{42 => %Connection{pid: pid, type: :sqlite}}
      end)

      ref = Process.monitor(pid)

      assert :ok = Melocoton.Pool.release(42)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
      refute Process.alive?(pid)
      refute Map.has_key?(:sys.get_state(Melocoton.Pool), 42)
    end

    test "is a no-op when the id is not cached" do
      :sys.replace_state(Melocoton.Pool, fn _ -> %{} end)

      assert :ok = Melocoton.Pool.release(999)
      assert :sys.get_state(Melocoton.Pool) == %{}
    end

    test "tolerates an already-dead cached pid" do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      assert_receive {:DOWN, ^ref, :process, ^dead_pid, _}

      :sys.replace_state(Melocoton.Pool, fn _ ->
        %{7 => %Connection{pid: dead_pid, type: :sqlite}}
      end)

      assert :ok = Melocoton.Pool.release(7)
      refute Map.has_key?(:sys.get_state(Melocoton.Pool), 7)
    end

    test "only releases the requested id" do
      {:ok, keep_pid} = Agent.start(fn -> :ok end)
      {:ok, drop_pid} = Agent.start(fn -> :ok end)

      :sys.replace_state(Melocoton.Pool, fn _ ->
        %{
          1 => %Connection{pid: keep_pid, type: :sqlite},
          2 => %Connection{pid: drop_pid, type: :sqlite}
        }
      end)

      assert :ok = Melocoton.Pool.release(2)

      state = :sys.get_state(Melocoton.Pool)
      assert Map.has_key?(state, 1)
      refute Map.has_key?(state, 2)
      assert Process.alive?(keep_pid)

      GenServer.stop(keep_pid)
    end
  end
end
