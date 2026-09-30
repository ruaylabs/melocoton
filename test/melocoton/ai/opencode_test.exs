defmodule Melocoton.AI.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Melocoton.AI

  @schema %{type: :sqlite, tables: [], indexes: [], triggers: [], functions: []}
  @messages [%{role: "user", content: "hello"}]

  setup do
    Req.Test.stub(__MODULE__, fn conn ->
      send(self(), {:request_headers, conn.req_headers})
      body = %{"id" => "response-1", "model" => "test-model"}

      body =
        if String.ends_with?(conn.request_path, "/responses") do
          Map.merge(body, %{
            "object" => "response",
            "status" => "completed",
            "output" => [
              %{
                "type" => "message",
                "role" => "assistant",
                "content" => [
                  %{"type" => "output_text", "text" => "SELECT 1;", "annotations" => []}
                ]
              }
            ],
            "usage" => %{"input_tokens" => 100, "output_tokens" => 20, "total_tokens" => 120}
          })
        else
          Map.merge(body, %{
            "object" => "chat.completion",
            "choices" => [
              %{
                "index" => 0,
                "message" => %{"role" => "assistant", "content" => "SELECT 1;"},
                "finish_reason" => "stop"
              }
            ],
            "usage" => %{"prompt_tokens" => 100, "completion_tokens" => 20, "total_tokens" => 120}
          })
        end

      Req.Test.json(conn, body)
    end)

    :ok
  end

  test "retains usage and OpenCode session headers alongside caller HTTP options" do
    vsn = to_string(Application.spec(:melocoton, :vsn))

    for session_id <- [nil, 42] do
      assert {:ok, attrs} =
               AI.chat(@schema, @messages,
                 model: "opencode:go/custom-model",
                 session_id: session_id,
                 api_key: "test-key",
                 req_http_options: [
                   plug: {Req.Test, __MODULE__},
                   headers: %{"x-custom" => "kept"}
                 ]
               )

      assert_receive {:request_headers, headers}
      expected_session = to_string(session_id || "melocoton-#{vsn}")
      assert {"x-opencode-session", expected_session} in headers
      assert {"user-agent", "melocoton/#{vsn}"} in headers
      assert {"x-custom", "kept"} in headers
      assert attrs.content == "SELECT 1;"
      assert attrs.provider == "opencode"
      assert attrs.model == "go/custom-model"
      assert attrs.input_tokens == 100
      assert attrs.output_tokens == 20
      assert attrs.total_tokens == 120
    end
  end

  test "chat session IDs do not leak into other providers' ReqLLM options" do
    for model <- ["openai:gpt-4o-mini", "minimax:MiniMax-M2.7", "ollama:qwen:latest"] do
      assert {:ok, attrs} =
               AI.chat(@schema, @messages,
                 model: model,
                 session_id: 42,
                 api_key: "test-key",
                 req_http_options: [plug: {Req.Test, __MODULE__}]
               )

      assert attrs.content == "SELECT 1;"
      assert attrs.total_tokens == 120
      assert %Decimal{} = attrs.total_cost
    end
  end
end
