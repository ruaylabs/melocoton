defmodule Melocoton.AI.OpenCode do
  @moduledoc """
  OpenCode provider supporting Free, Go, and Zen tiers.

  All tiers use the same opencode.ai API key with different base URLs:
    - Free/Zen: https://opencode.ai/zen/v1
    - Go:       https://opencode.ai/zen/go/v1

  Model values use the format `tier/model-name`, e.g. `zen/gpt-5.5` or `go/deepseek-v4-flash`.
  """

  @zen_base_url "https://opencode.ai/zen/v1"
  @go_base_url "https://opencode.ai/zen/go/v1"

  def chat(messages, opts \\ []) do
    api_key =
      opts[:api_key] ||
        Application.get_env(:req_llm, :opencode_api_key) ||
        System.get_env("OPENCODE_API_KEY")

    model = opts[:model]

    if is_nil(api_key) or api_key == "" do
      {:error, "OPENCODE_API_KEY not configured"}
    else
      {base_url, model_name} = resolve_endpoint(model)

      model_spec =
        ReqLLM.model!(%{
          id: model_name,
          provider: :openai,
          base_url: base_url,
          api_key: api_key
        })

      case ReqLLM.generate_text(model_spec, messages,
             api_key: api_key,
             receive_timeout: 300_000,
             req_http_options: [headers: request_headers(opts)]
           ) do
        {:ok, %{message: %{content: content}}} ->
          {:ok, extract_text(content)}

        {:error, error} ->
          {:error, "OpenCode error: #{inspect(error)}"}
      end
    end
  end

  defp request_headers(opts) do
    vsn = to_string(Application.spec(:melocoton, :vsn))
    session_id = opts[:session_id] || "melocoton-#{vsn}"

    [
      {"x-opencode-session", session_id},
      {"user-agent", "melocoton/#{vsn}"}
    ]
  end

  defp resolve_endpoint(model) do
    case String.split(model, "/", parts: 2) do
      ["go", name] -> {@go_base_url, name}
      ["zen", name] -> {@zen_base_url, name}
      _ -> {@zen_base_url, model}
    end
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn
      %{text: text} -> text
      %{content: text} when is_binary(text) -> text
      other -> to_string(other)
    end)
  end

  defp extract_text(other), do: to_string(other)
end
