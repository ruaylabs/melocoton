defmodule MelocotonWeb.ThemeContrastTest do
  use ExUnit.Case, async: true

  @css File.read!(Path.expand("../../../assets/css/app.css", __DIR__))

  for theme <- ["light", "dark"] do
    test "#{theme} syntax comments and typed cells meet 4.5:1 contrast" do
      theme = unquote(theme)
      tokens = declarations(~s([data-theme="#{theme}"]))
      surfaces = Enum.map(~w(--bg-primary --bg-secondary --bg-tertiary), &Map.fetch!(tokens, &1))

      for background <- surfaces do
        assert_contrast(tokens["--syntax-comment"], background)
        assert_contrast(tokens["--syntax-table"], background)
      end

      for type <- ~w(bool-true bool-false null timestamp url array json number pk) do
        selector = ".cell-#{type}"
        base = declarations(selector)
        overrides = declarations(~s([data-theme="#{theme}"] #{selector}))
        styles = Map.merge(base, overrides)
        foreground = resolve(styles["color"], tokens)

        backgrounds =
          if styles["background"],
            do: [resolve(styles["background"], tokens)],
            else: surfaces

        for background <- backgrounds do
          assert_contrast(foreground, background)
        end
      end
    end
  end

  for theme <- ["light", "dark"] do
    test "#{theme} chat inline code uses contrasting theme colors instead of bubble text" do
      tokens = declarations(~s([data-theme="#{unquote(theme)}"]))
      code = declarations(".ai-markdown code")
      inline_code = declarations(".ai-markdown :not(pre) > code")

      assert inline_code["color"] == "var(--text-primary)"

      assert_contrast(
        resolve(inline_code["color"], tokens),
        resolve(code["background"], tokens)
      )

      # Fenced code remains transparent and keeps its inherited/syntax colors.
      block_code = declarations(".ai-markdown pre code")
      assert block_code["background"] == "transparent"
      refute Map.has_key?(block_code, "color")
    end
  end

  defp declarations(selector) do
    case Regex.run(~r/(?:^|\n)#{Regex.escape(selector)}\s*\{([^}]+)\}/, @css) do
      [_, body] ->
        ~r/([\w-]+):\s*([^;]+);/
        |> Regex.scan(body)
        |> Map.new(fn [_, property, value] -> {property, String.trim(value)} end)

      nil ->
        %{}
    end
  end

  defp resolve("var(" <> rest, tokens), do: Map.fetch!(tokens, String.trim_trailing(rest, ")"))
  defp resolve(color, _tokens), do: color

  defp assert_contrast(foreground, background) do
    first = luminance(foreground)
    second = luminance(background)
    ratio = (max(first, second) + 0.05) / (min(first, second) + 0.05)

    assert ratio >= 4.5,
           "#{foreground} on #{background} has contrast #{Float.round(ratio, 2)}:1"
  end

  defp luminance("#" <> hex) do
    [red, green, blue] =
      for <<channel::binary-size(2) <- hex>> do
        value = String.to_integer(channel, 16) / 255
        if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
      end

    red * 0.2126 + green * 0.7152 + blue * 0.0722
  end
end
