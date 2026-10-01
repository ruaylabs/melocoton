defmodule Melocoton.AI.Models do
  @providers [
    {"anthropic", "Anthropic",
     [
       {"claude-sonnet-5-5", "Claude Sonnet 5.5"},
       {"claude-opus-5-5", "Claude Opus 5.5"},
       {"claude-fable-5-1", "Claude Fable 5.1"},
       {"claude-haiku-4-5", "Claude Haiku 4.5"}
     ]},
    {"openai", "OpenAI",
     [
       {"gpt-4o", "GPT-4o"},
       {"gpt-4o-mini", "GPT-4o Mini"},
       {"gpt-4.1", "GPT-4.1"},
       {"gpt-4.1-mini", "GPT-4.1 Mini"},
       {"gpt-4.1-nano", "GPT-4.1 Nano"}
     ]},
    {"openrouter", "OpenRouter",
     [
       {"anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5"},
       {"anthropic/claude-opus-5.5", "Claude Opus 5.5"},
       {"anthropic/claude-fable-5.1", "Claude Fable 5.1"},
       {"anthropic/claude-haiku-4.5", "Claude Haiku 4.5"},
       {"openai/gpt-4o", "GPT-4o"},
       {"google/gemini-2.5-pro", "Gemini 2.5 Pro"},
       {"minimax/MiniMax-M2.7", "MiniMax M2.7"}
     ]},
    {"minimax", "MiniMax",
     [
       {"MiniMax-M2.7", "MiniMax M2.7"},
       {"MiniMax-M2.7-highspeed", "MiniMax M2.7 Highspeed"},
       {"MiniMax-M2.5", "MiniMax M2.5"},
       {"MiniMax-M2.5-highspeed", "MiniMax M2.5 Highspeed"},
       {"MiniMax-M2.1", "MiniMax M2.1"},
       {"MiniMax-M2", "MiniMax M2"}
     ]},
    {"ollama", "Ollama", :dynamic},
    {"opencode", "OpenCode",
     [
       {"zen/deepseek-v4-flash-free", "Free: DeepSeek V4 Flash Free"},
       {"zen/big-pickle", "Free: Big Pickle"},
       {"zen/nemotron-3-super-free", "Free: Nemotron 3 Super Free"},
       {"go/deepseek-v4-flash", "Go: DeepSeek V4 Flash"},
       {"go/deepseek-v4-pro", "Go: DeepSeek V4 Pro"},
       {"go/deepseek-v4.1-flash", "Go: DeepSeek V4.1 Flash"},
       {"go/deepseek-flash", "Go: DeepSeek Flash"},
       {"go/deepseek-v4-flash-vision-exp", "Go: DeepSeek V4 Flash Vision Exp"},
       {"go/glm-5.3", "Go: GLM-5.3"},
       {"go/glm-5.3-flash", "Go: GLM-5.3 Flash"},
       {"go/glm-5.2", "Go: GLM-5.2"},
       {"go/glm-5.1", "Go: GLM-5.1"},
       {"go/glm-5", "Go: GLM-5"},
       {"go/gpt-6-luna", "Go: GPT 6 Luna"},
       {"go/gpt-5.6-luna", "Go: GPT 5.6 Luna"},
       {"go/grok-4.7", "Go: Grok 4.7"},
       {"go/grok-4.6", "Go: Grok 4.6"},
       {"go/grok-4.5", "Go: Grok 4.5"},
       {"go/kimi-k3", "Go: Kimi K3"},
       {"go/kimi-k2.7-code", "Go: Kimi K2.7 Code"},
       {"go/kimi-k2.6", "Go: Kimi K2.6"},
       {"go/kimi-k2.5", "Go: Kimi K2.5"},
       {"go/longcat-2.0", "Go: LongCat 2.0"},
       {"go/longcat-2.5-preview-free", "Free: LongCat 2.5 Preview"},
       {"go/mimo-v2.6-pro", "Go: MiMo-V2.6-Pro"},
       {"go/mimo-v2.6-flash", "Go: MiMo-V2.6-Flash"},
       {"go/mimo-v2.5-pro", "Go: MiMo-V2.5-Pro"},
       {"go/mimo-v2.5", "Go: MiMo-V2.5"},
       {"go/mimo-v2-pro", "Go: MiMo-V2-Pro"},
       {"go/mimo-v2-omni", "Go: MiMo-V2-Omni"},
       {"go/minimax-m3", "Go: MiniMax M3"},
       {"go/minimax-m2.7", "Go: MiniMax M2.7"},
       {"go/minimax-m2.5", "Go: MiniMax M2.5"},
       {"go/muse-spark-1.3-contributor", "Go: Muse Spark 1.3 Contributor"},
       {"go/muse-spark-1.2-contributor", "Go: Muse Spark 1.2 Contributor"},
       {"go/qwen3.8-max", "Go: Qwen3.8 Max"},
       {"go/qwen3.8-flash", "Go: Qwen3.8 Flash"},
       {"go/qwen3.7-max", "Go: Qwen3.7 Max"},
       {"go/qwen3.7-plus", "Go: Qwen3.7 Plus"},
       {"go/qwen3.6-plus", "Go: Qwen3.6 Plus"},
       {"go/qwen3.5-plus", "Go: Qwen3.5 Plus"},
       {"go/hy4-preview", "Go: Hy4 Preview"},
       {"go/hy3", "Go: Hy3"},
       {"go/hy3-preview", "Go: Hy3 Preview"},
       {"go/space-bunny-free", "Free: Space Bunny"},
       {"zen/gpt-5.5", "Zen: GPT 5.5"},
       {"zen/gpt-5.2-codex", "Zen: GPT 5.2 Codex"},
       {"zen/gpt-5.1-codex", "Zen: GPT 5.1 Codex"},
       {"zen/claude-sonnet-5-5", "Zen: Claude Sonnet 5.5"},
       {"zen/claude-opus-5-5", "Zen: Claude Opus 5.5"},
       {"zen/claude-fable-5-1", "Zen: Claude Fable 5.1"},
       {"zen/claude-haiku-4-5", "Zen: Claude Haiku 4.5"},
       {"zen/gemini-3.5-flash", "Zen: Gemini 3.5 Flash"}
     ]}
  ]

  def providers, do: @providers

  def provider_options do
    Enum.map(@providers, fn {id, label, _} -> {label, id} end)
  end

  def model_options("ollama"), do: Melocoton.AI.Ollama.list_models()

  def model_options(provider_id) do
    case Enum.find(@providers, fn {id, _, _} -> id == provider_id end) do
      {_, _, models} when is_list(models) -> Enum.map(models, fn {id, label} -> {label, id} end)
      _ -> []
    end
  end

  def parse_model_string(nil), do: {nil, nil}
  def parse_model_string(""), do: {nil, nil}

  def parse_model_string(model_string) do
    case String.split(model_string, ":", parts: 2) do
      [provider, model] -> {provider, model}
      _ -> {nil, nil}
    end
  end

  def required_api_key("anthropic"), do: "anthropic_api_key"
  def required_api_key("openai"), do: "openai_api_key"
  def required_api_key("openrouter"), do: "openrouter_api_key"
  def required_api_key("minimax"), do: "minimax_api_key"
  def required_api_key("ollama"), do: nil
  def required_api_key("opencode"), do: "opencode_api_key"
  def required_api_key(_), do: nil

  def build_model_string(nil, _), do: nil
  def build_model_string(_, nil), do: nil
  def build_model_string("", _), do: nil
  def build_model_string(_, ""), do: nil
  def build_model_string(provider, model), do: "#{provider}:#{model}"
end
