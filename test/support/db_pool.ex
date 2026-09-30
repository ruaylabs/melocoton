defmodule Melocoton.Test.DBPool do
  @moduledoc """
  Waits for a DBConnection pool to shut down.

  DBConnection's watcher terminates the pool with `:shutdown` once its owner
  exits, so `GenServer.stop(pid, :normal)` in `on_exit/1` races that teardown
  and fails with an exit-reason mismatch (reliable on db_connection >= 2.10.2,
  where pool connections terminate synchronously). Waiting for the pool to
  die on its own avoids the race.
  """

  @doc "Waits for the pool `pid` to terminate, killing it after `timeout`."
  def stop(pid, timeout \\ 5_000) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, _, _, _} -> :ok
    after
      timeout ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          timeout -> :ok
        end
    end
  end
end
