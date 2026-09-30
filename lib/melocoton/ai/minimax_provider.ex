defmodule Melocoton.AI.MinimaxProvider do
  @moduledoc """
  MiniMax LLM provider using their OpenAI-compatible chat completions API.

  API base: https://api.minimax.io/v1
  Available models: MiniMax-M2.7, MiniMax-M2.7-highspeed, MiniMax-M2.5,
  MiniMax-M2.5-highspeed, MiniMax-M2.1, MiniMax-M2.

  ## Usage

      AI_MODEL=minimax:MiniMax-M2.7
      MINIMAX_API_KEY=sk-cp-...
  """

  def chat(messages, opts \\ []) do
    api_key =
      opts[:api_key] ||
        Application.get_env(:req_llm, :minimax_api_key) ||
        System.get_env("MINIMAX_API_KEY")

    model = opts[:model] || "MiniMax-M2.7"

    if api_key in [nil, ""] do
      {:error, "MINIMAX_API_KEY not configured"}
    else
      request_opts =
        [
          max_tokens: 4096,
          receive_timeout: :timer.seconds(300),
          req_http_options: [connect_options: [timeout: :timer.seconds(60)]]
        ]
        |> Keyword.merge(Keyword.delete(opts, :model))
        |> Keyword.put(:api_key, api_key)

      ReqLLM.generate_text("minimax:#{model}", messages, request_opts)
    end
  end
end
