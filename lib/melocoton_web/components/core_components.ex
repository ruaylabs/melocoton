defmodule MelocotonWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as modals, tables, and
  forms. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The default components use Tailwind CSS, a utility-first CSS framework.
  See the [Tailwind CSS documentation](https://tailwindcss.com) to learn
  how to customize them or feel free to swap in another framework altogether.

  Icons are provided by [Lucide](https://lucide.dev) and [Devicon](https://devicon.dev). See `icon/1` for usage.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  import MelocotonWeb.Gettext

  @doc """
  Chooses black or white text for an opaque hex background using WCAG relative luminance.
  The higher-contrast choice meets the 4.5:1 normal-text threshold for any RGB color.
  """
  def contrast_foreground("#" <> hex) when byte_size(hex) in [3, 6] do
    hex =
      if byte_size(hex) == 3 do
        for <<digit <- hex>>, into: "", do: <<digit, digit>>
      else
        hex
      end

    case Integer.parse(hex, 16) do
      {rgb, ""} ->
        <<red, green, blue>> = <<rgb::24>>

        [red, green, blue] =
          Enum.map([red, green, blue], fn channel ->
            value = channel / 255
            if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
          end)

        luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        black_contrast = (luminance + 0.05) / 0.05
        white_contrast = 1.05 / (luminance + 0.05)
        if black_contrast >= white_contrast, do: "#000000", else: "#ffffff"

      _ ->
        "#000000"
    end
  end

  def contrast_foreground(_color), do: "#000000"

  @doc """
  Renders a modal.

  ## Examples

      <.modal id="confirm-modal">
        This is a modal.
      </.modal>

  JS commands may be passed to the `:on_cancel` to configure
  the closing/cancel event, for example:

      <.modal id="confirm" on_cancel={JS.navigate(~p"/posts")}>
        This is another modal.
      </.modal>

  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :title, :string, required: true
  attr :icon, :string, default: nil
  attr :max_width, :string, default: "max-w-lg"
  attr :on_cancel, JS, default: %JS{}
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={@show && show_modal(@id)}
      phx-remove={hide_modal(@id)}
      data-cancel={JS.exec(@on_cancel, "phx-remove")}
      data-show-modal={show_modal(@id)}
      class="relative z-50 hidden"
    >
      <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
        <div
          id={"#{@id}-bg"}
          class="absolute inset-0 bg-black/40"
          aria-hidden="true"
        />
        <.focus_wrap
          id={"#{@id}-container"}
          phx-window-keydown={JS.exec("data-cancel", to: "##{@id}")}
          phx-key="escape"
          phx-click-away={JS.exec("data-cancel", to: "##{@id}")}
          class={"relative flex flex-col max-h-[calc(100dvh-2rem)] w-full #{@max_width} mx-auto rounded-lg shadow-xl overflow-hidden z-10"}
          style="background: var(--bg-primary); border: 1px solid var(--border-medium);"
        >
          <div
            class="px-4 py-3 flex shrink-0 items-center justify-between"
            style="background: var(--bg-secondary); border-bottom: 1px solid var(--border-medium);"
          >
            <div class="flex items-center gap-2 text-sm font-medium">
              <.icon :if={@icon} name={@icon} class="size-4" style="color: var(--text-tertiary);" />
              <span>{@title}</span>
            </div>
            <button
              phx-click={JS.exec("data-cancel", to: "##{@id}")}
              aria-label={gettext("close")}
              class="p-1 rounded hover:bg-black/10 dark:hover:bg-white/10"
              style="color: var(--text-tertiary);"
            >
              <.icon name="lucide-x" class="size-4" />
            </button>
          </div>

          <div id={"#{@id}-content"} class="min-h-0 overflow-y-auto">
            {render_slot(@inner_block)}
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  @doc """
  Renders a modal for viewing full cell content. Populated via JS.
  """
  def cell_detail_modal(assigns) do
    ~H"""
    <div
      id="cell-detail-modal"
      class="relative z-50 hidden"
      data-cancel={hide_modal("cell-detail-modal")}
      data-show-modal={show_modal("cell-detail-modal")}
    >
      <div class="fixed inset-0 z-50 flex items-center justify-center">
        <div
          id="cell-detail-modal-bg"
          class="absolute inset-0 bg-black/40"
          aria-hidden="true"
        />
        <.focus_wrap
          id="cell-detail-modal-container"
          phx-window-keydown={JS.exec("data-cancel", to: "#cell-detail-modal")}
          phx-key="escape"
          phx-click-away={JS.exec("data-cancel", to: "#cell-detail-modal")}
          class="relative w-full max-w-2xl mx-auto rounded-lg shadow-xl overflow-hidden z-10"
          style="background: var(--bg-primary); border: 1px solid var(--border-medium);"
        >
          <div
            class="px-4 py-3 flex items-center justify-between"
            style="background: var(--bg-secondary); border-bottom: 1px solid var(--border-medium);"
          >
            <div class="flex items-center gap-2 text-sm font-medium">
              <.icon name="lucide-file-text" class="size-4" style="color: var(--text-tertiary);" />
              <span>Cell content</span>
            </div>
            <div class="flex items-center gap-1">
              <div
                id="cell-detail-format-toggle"
                class="hidden items-center gap-0.5 mr-1"
              >
                <button
                  id="cell-detail-formatted-btn"
                  class="px-2 py-1 text-xs rounded font-medium"
                  style="background: var(--focus-color); color: white;"
                >
                  Formatted
                </button>
                <button
                  id="cell-detail-raw-btn"
                  class="px-2 py-1 text-xs rounded font-medium"
                  style="background: var(--bg-tertiary); color: var(--text-secondary); border: 0.5px solid var(--border-medium);"
                >
                  Raw
                </button>
              </div>
              <button
                id="cell-detail-copy-btn"
                class="p-1.5 rounded hover:bg-black/10 dark:hover:bg-white/10 flex items-center gap-1 text-xs"
                style="color: var(--text-tertiary);"
                title="Copy to clipboard"
              >
                <.icon name="lucide-copy" class="size-3.5" />
                <span>Copy</span>
              </button>
              <button
                phx-click={JS.exec("data-cancel", to: "#cell-detail-modal")}
                aria-label="close"
                class="p-1 rounded hover:bg-black/10 dark:hover:bg-white/10"
                style="color: var(--text-tertiary);"
              >
                <.icon name="lucide-x" class="size-4" />
              </button>
            </div>
          </div>
          <div class="p-4 max-h-[70vh] overflow-auto">
            <pre
              id="cell-detail-content"
              class="text-xs whitespace-pre-wrap break-all"
              style="color: var(--text-primary); font-family: var(--font-mono, monospace);"
            ></pre>
          </div>
        </.focus_wrap>
      </div>
    </div>
    """
  end

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      phx-hook="AutoHideFlash"
      role="alert"
      class={[
        "fixed top-2 right-2 mr-2 w-80 sm:w-96 z-50 rounded-lg p-3 ring-1",
        @kind == :info &&
          "bg-emerald-50 dark:bg-emerald-900/30 text-emerald-800 dark:text-emerald-200 ring-emerald-500 dark:ring-emerald-600",
        @kind == :error &&
          "bg-rose-50 dark:bg-rose-900/30 text-rose-900 dark:text-rose-200 ring-rose-500 dark:ring-rose-600"
      ]}
      {@rest}
    >
      <p :if={@title} class="flex items-center gap-1.5 text-sm font-semibold leading-6">
        <.icon :if={@kind == :info} name="lucide-info" class="size-4" />
        <.icon :if={@kind == :error} name="lucide-alert-circle" class="size-4" />
        {@title}
      </p>
      <p class="mt-2 text-sm leading-5">{msg}</p>
      <button
        type="button"
        class="group absolute top-1 right-1 p-2 opacity-50 hover:opacity-100"
        aria-label={gettext("close")}
      >
        <.icon name="lucide-x" class="size-5" />
      </button>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id}>
      <.flash kind={:info} title={gettext("Success!")} flash={@flash} />
      <.flash kind={:error} title={gettext("Error!")} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="lucide-loader-2" class="ml-1 size-3 animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        {gettext("Hang in there while we get back on track")}
        <.icon name="lucide-loader-2" class="ml-1 size-3 animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Renders a simple form.

  ## Examples

      <.simple_form for={@form} phx-change="validate" phx-submit="save">
        <.input field={@form[:email]} label="Email"/>
        <.input field={@form[:username]} label="Username" />
        <:actions>
          <.button>Save</.button>
        </:actions>
      </.simple_form>
  """
  attr :for, :any, required: true, doc: "the data structure for the form"
  attr :as, :any, default: nil, doc: "the server side parameter to collect all input under"

  attr :rest, :global,
    include: ~w(autocomplete name rel action enctype method novalidate target multipart),
    doc: "the arbitrary HTML attributes to apply to the form tag"

  slot :inner_block, required: true
  slot :actions, doc: "the slot for form actions, such as a submit button"

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest} autocomplete="off" autocapitalize="off">
      <div class="space-y-8">
        {render_slot(@inner_block, f)}
        <div :for={action <- @actions} class="mt-2 flex items-center justify-end gap-6">
          {render_slot(action, f)}
        </div>
      </div>
    </.form>
    """
  end

  @doc """
  Renders a button.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" class="ml-2">Send!</.button>
  """
  attr :type, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value)

  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "px-3 py-1.5 text-xs bg-app-accent-light text-white rounded hover:bg-app-accent-light/90",
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as hidden and radio,
  are best written directly in your templates.

  ## Examples

      <.input field={@form[:email]} type="email" />
      <.input name="my-input" errors={["oh no!"]} />
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               range search select tel text textarea time url week)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div>
      <label class="flex items-center gap-4 text-sm leading-6 text-zinc-600">
        <input type="hidden" name={@name} value="false" disabled={@rest[:disabled]} />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class="rounded border-zinc-300 text-zinc-900 focus:ring-0"
          {@rest}
        />
        {@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="space-y-1">
      <.label for={@id}>{@label}</.label>
      <select
        id={@id}
        name={@name}
        class="w-full appearance-none px-2 py-1.5 text-xs border border-app-border-light dark:border-app-border-dark rounded bg-app-input-light dark:bg-app-input-dark pr-8 dark-transition"
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div>
      <.label for={@id}>{@label}</.label>
      <textarea
        id={@id}
        name={@name}
        class={[
          "mt-2 block w-full rounded-lg text-zinc-900 focus:ring-0 sm:text-sm sm:leading-6 min-h-[6rem]",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
      ><%= Phoenix.HTML.Form.normalize_value("textarea", @value) %></textarea>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="space-y-1">
      <.label :if={@label} for={@id}>{@label}</.label>
      <input
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        class={[
          "w-full px-2 py-1.5 text-xs border border-app-border-light dark:border-app-border-dark rounded bg-app-input-light dark:bg-app-input-dark dark-transition",
          @errors == [] && "border-zinc-300 focus:border-zinc-400",
          @errors != [] && "border-rose-400 focus:border-rose-400"
        ]}
        {@rest}
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
      />
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  @doc """
  Renders a label.
  """
  attr :for, :string, default: nil
  slot :inner_block, required: true

  def label(assigns) do
    ~H"""
    <label for={@for} class="block text-xs font-medium">
      {render_slot(@inner_block)}
    </label>
    """
  end

  @doc """
  Generates a generic error message.
  """
  slot :inner_block, required: true

  def error(assigns) do
    ~H"""
    <p class="mt-3 flex gap-3 text-sm leading-6 text-rose-600">
      <.icon name="lucide-alert-circle" class="mt-0.5 size-5 flex-none" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  attr :class, :string, default: nil

  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", @class]}>
      <div>
        <h1 class="text-lg font-semibold leading-8 text-zinc-800">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-2 text-sm leading-6 text-zinc-600">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc ~S"""
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id"><%= user.id %></:col>
        <:col :let={user} label="username"><%= user.username %></:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <div class="overflow-y-auto px-4 sm:overflow-visible sm:px-0">
      <table class="w-[40rem] mt-11 sm:w-full">
        <thead class="text-sm text-left leading-6 text-zinc-500">
          <tr>
            <th :for={col <- @col} class="p-0 pb-4 pr-6 font-normal">{col[:label]}</th>
            <th :if={@action != []} class="relative p-0 pb-4">
              <span class="sr-only">{gettext("Actions")}</span>
            </th>
          </tr>
        </thead>
        <tbody
          id={@id}
          phx-update={match?(%Phoenix.LiveView.LiveStream{}, @rows) && "stream"}
          class="relative divide-y divide-zinc-100 border-t border-zinc-200 text-sm leading-6 text-zinc-700"
        >
          <tr :for={row <- @rows} id={@row_id && @row_id.(row)} class="group hover:bg-zinc-50">
            <td
              :for={{col, i} <- Enum.with_index(@col)}
              phx-click={@row_click && @row_click.(row)}
              class={["relative p-0", @row_click && "hover:cursor-pointer"]}
            >
              <div class="block py-4 pr-6">
                <span class="absolute -inset-y-px right-0 -left-4 group-hover:bg-zinc-50 sm:rounded-l-xl" />
                <span class={["relative", i == 0 && "font-semibold text-zinc-900"]}>
                  {render_slot(col, @row_item.(row))}
                </span>
              </div>
            </td>
            <td :if={@action != []} class="relative w-14 p-0">
              <div class="relative whitespace-nowrap py-4 text-right text-sm font-medium">
                <span class="absolute -inset-y-px -right-4 left-0 group-hover:bg-zinc-50 sm:rounded-r-xl" />
                <span
                  :for={action <- @action}
                  class="relative ml-4 font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
                >
                  {render_slot(action, @row_item.(row))}
                </span>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title"><%= @post.title %></:item>
        <:item title="Views"><%= @post.views %></:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <div class="mt-14">
      <dl class="-my-4 divide-y divide-zinc-100">
        <div :for={item <- @item} class="flex gap-4 py-4 text-sm leading-6 sm:gap-8">
          <dt class="w-1/4 flex-none text-zinc-500">{item.title}</dt>
          <dd class="text-zinc-700">{render_slot(item)}</dd>
        </div>
      </dl>
    </div>
    """
  end

  @doc """
  Renders a back navigation link.

  ## Examples

      <.back navigate={~p"/posts"}>Back to posts</.back>
  """
  attr :navigate, :any, required: true
  slot :inner_block, required: true

  def back(assigns) do
    ~H"""
    <div class="mt-16">
      <.link
        navigate={@navigate}
        class="text-sm font-semibold leading-6 text-zinc-900 hover:text-zinc-700"
      >
        <.icon name="lucide-arrow-left" class="size-3" />
        {render_slot(@inner_block)}
      </.link>
    </div>
    """
  end

  @doc """
  Renders an icon from Lucide or brand icons.

  Lucide icons use the `lucide-` prefix and are rendered via CSS masks
  bundled by the Tailwind plugin in `assets/tailwind.config.js`.
  They inherit `currentColor` for styling.

  Brand icons use the `brand-` prefix and render as inline SVGs
  with their original brand colors.

  ## Examples

      <.icon name="lucide-search" class={["w-4", "h-4"]} />
      <.icon name="brand-postgresql" class="size-5" />
      <.icon name="lucide-lock" class="size-3" style="color: red;" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: nil
  attr :style, :string, default: nil

  def icon(%{name: "lucide-" <> _} = assigns) do
    ~H"""
    <span class={[@name | List.wrap(@class)]} style={@style} />
    """
  end

  # Brand icons — 3 database vendor logos with original brand colors
  @external_resource "priv/static/icons/brand/postgresql.svg"
  @external_resource "priv/static/icons/brand/mysql.svg"
  @external_resource "priv/static/icons/brand/sqlite.svg"

  @brand_icons (for name <- ~w(postgresql mysql sqlite), into: %{} do
                  svg = File.read!("priv/static/icons/brand/#{name}.svg")
                  [_, inner] = Regex.run(~r/<svg[^>]*>(.*)<\/svg>/s, svg)
                  {name, inner}
                end)

  def icon(%{name: "brand-" <> name} = assigns) do
    assigns = assign(assigns, :svg_body, @brand_icons[name])

    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 128 128"
      class={List.wrap(@class)}
      style={@style}
    >
      {Phoenix.HTML.raw(@svg_body)}
    </svg>
    """
  end

  @doc """
  Renders a read-only SQL snippet with syntax highlighting.

  The SQL is wrapped in a fenced markdown block and rendered through
  MDEx so it picks up the same highlighting theme as the AI chat panel.
  """
  attr :sql, :string, required: true
  attr :class, :any, default: "text-xs"

  def sql_block(assigns) do
    ~H"""
    <div class={["ai-sql-block rounded overflow-hidden", @class]}>
      {Makeup.highlight(@sql,
        lexer: MakeupSql,
        formatter: Makeup.Formatters.HTML.HTMLFormatter
      )
      |> Phoenix.HTML.raw()}
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 100,
      transition:
        {"transition-all transform ease-out duration-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 100,
      transition:
        {"transition-all transform ease-in duration-100",
         "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  def show_modal(js \\ %JS{}, id) when is_binary(id) do
    js
    |> JS.show(to: "##{id}")
    |> JS.show(
      to: "##{id}-bg",
      time: 100,
      transition: {"transition-all transform ease-out duration-100", "opacity-0", "opacity-100"}
    )
    |> JS.show(
      to: "##{id}-container",
      display: "flex",
      time: 100,
      transition:
        {"transition-all transform ease-out duration-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
    |> JS.add_class("overflow-hidden", to: "body")
    |> JS.focus_first(to: "##{id}-content")
  end

  def hide_modal(js \\ %JS{}, id) do
    js
    |> JS.hide(
      to: "##{id}-bg",
      transition: {"transition-all transform ease-in duration-100", "opacity-100", "opacity-0"}
    )
    |> hide("##{id}-container")
    |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
    |> JS.remove_class("overflow-hidden", to: "body")
    |> JS.pop_focus()
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(MelocotonWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(MelocotonWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end

  @doc """
  Highlights occurrences of `term` within `value` using `<mark>` tags.
  """
  attr :value, :any, required: true
  attr :term, :string, required: true

  def put_mark(%{value: value, term: term} = assigns) do
    str =
      case value do
        s when is_binary(s) -> s
        other -> inspect(other, structs: false)
      end

    escaped_str = Phoenix.HTML.html_escape(str) |> Phoenix.HTML.safe_to_string()
    escaped_term = Phoenix.HTML.html_escape(term) |> Phoenix.HTML.safe_to_string()

    match =
      escaped_str
      |> String.replace(escaped_term, "<mark>#{escaped_term}</mark>")
      |> Phoenix.HTML.raw()

    assigns = assign(assigns, :value, match)

    ~H"""
    {@value}
    """
  end

  @doc """
  Renders a database cell value with type-aware formatting.

  Handles null, boolean, URL, JSON, long text, timestamp, date, time,
  number, and plain text values. Supports optional filter term highlighting.
  """
  attr :value, :any, required: true
  attr :filter, :string, default: ""

  @max_cell_length 100

  def data_cell(assigns) do
    assigns = assign(assigns, :type, cell_type(assigns.value))

    ~H"""
    <%= case @type do %>
      <% :null -> %>
        <span class="cell-null">null</span>
      <% :boolean -> %>
        <span class={if @value, do: "cell-bool-true", else: "cell-bool-false"}>
          {to_string(@value)}
        </span>
      <% :url -> %>
        <span class="cell-url" title={@value}>
          <span :if={@filter == ""}>{@value}</span>
          <span :if={@filter != ""}><.put_mark value={@value} term={@filter} /></span>
        </span>
      <% :array -> %>
        <span class="cell-array cell-expandable" data-full-value={raw_cell_value(@value)}>
          <span :if={@filter == ""}>{format_array(@value)}</span>
          <span :if={@filter != ""}><.put_mark value={format_array(@value)} term={@filter} /></span>
        </span>
      <% :json -> %>
        <span class="cell-json cell-expandable" data-full-value={raw_cell_value(@value)}>
          <span :if={@filter == ""}>{format_cell_value(@value, :long_text)}</span>
          <span :if={@filter != ""}><.put_mark value={@value} term={@filter} /></span>
        </span>
      <% :long_text -> %>
        <span class="cell-long-text cell-expandable" data-full-value={@value}>
          <span :if={@filter == ""}>{format_cell_value(@value, :long_text)}…</span>
          <span :if={@filter != ""}><.put_mark value={@value} term={@filter} /></span>
        </span>
      <% :timestamp -> %>
        <span class="cell-timestamp">{Calendar.strftime(@value, "%Y-%m-%d %H:%M:%S")}</span>
      <% :date -> %>
        <span class="cell-timestamp">{Calendar.strftime(@value, "%Y-%m-%d")}</span>
      <% :time -> %>
        <span class="cell-timestamp">{Calendar.strftime(@value, "%H:%M:%S")}</span>
      <% :number -> %>
        <span class="cell-number">{@value}</span>
      <% _ -> %>
        <span :if={@filter == ""}>{to_display_string(@value)}</span>
        <span :if={@filter != ""}><.put_mark value={@value} term={@filter} /></span>
    <% end %>
    """
  end

  defp cell_type(nil), do: :null
  defp cell_type(value) when is_boolean(value), do: :boolean
  defp cell_type(%Date{}), do: :date
  defp cell_type(%Time{}), do: :time
  defp cell_type(%NaiveDateTime{}), do: :timestamp
  defp cell_type(%DateTime{}), do: :timestamp
  defp cell_type(%Decimal{}), do: :number
  defp cell_type(value) when is_list(value), do: :array
  defp cell_type(value) when is_map(value), do: :json
  defp cell_type(value) when is_binary(value) and binary_part(value, 0, 4) == "http", do: :url
  defp cell_type(value) when is_integer(value) or is_float(value), do: :number

  defp cell_type(value) when is_binary(value) do
    if json_string?(value), do: :json, else: :text
  end

  defp cell_type(_), do: :text

  defp json_string?(str) do
    trimmed = String.trim(str)

    (String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")) or
      (String.starts_with?(trimmed, "[") and String.ends_with?(trimmed, "]"))
  end

  defp format_cell_value(value, :long_text) when is_binary(value) do
    String.slice(value, 0, @max_cell_length)
  end

  defp format_cell_value(value, :long_text),
    do: String.slice(to_display_string(value), 0, @max_cell_length)

  defp format_cell_value(value, _type), do: value

  defp format_array(list) when is_list(list) do
    inner = Enum.map_join(list, ",", &format_array_element/1)
    "{#{inner}}"
  end

  defp format_array_element(value) when is_list(value), do: format_array(value)
  defp format_array_element(nil), do: "NULL"
  defp format_array_element(value) when is_binary(value), do: value
  defp format_array_element(value), do: to_string(value)

  defp raw_cell_value(value) when is_binary(value), do: value
  defp raw_cell_value(value) when is_list(value), do: format_array(value)
  defp raw_cell_value(value) when is_map(value), do: Jason.encode!(value)
  defp raw_cell_value(value), do: inspect(value, structs: false)

  defp to_display_string(value) when is_binary(value), do: value
  defp to_display_string(value) when is_list(value), do: format_array(value)
  defp to_display_string(value) when is_map(value), do: Jason.encode!(value)
  defp to_display_string(value), do: inspect(value, structs: false)
end
