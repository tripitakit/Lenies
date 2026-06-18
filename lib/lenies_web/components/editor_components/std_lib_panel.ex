defmodule LeniesWeb.EditorComponents.StdLibPanel do
  use LeniesWeb, :html

  attr :std_lib, :list, required: true

  def std_lib_panel(assigns) do
    ~H"""
    <section class="std-lib-panel">
      <header class="std-lib-head"><span class="std-lib-title">Std-lib</span></header>
      <div :for={{category, snippets} <- @std_lib} class="std-lib-cat">
        <div class="std-lib-cat-head">{category}</div>
        <article :for={s <- snippets} class="std-lib-card">
          <div class="std-lib-row1">
            <span class="std-lib-name">{s.name}</span>
            <span class="std-lib-kind">{kind_badge(s.kind)}</span>
            <span class="std-lib-sig">{s.signature}</span>
          </div>
          <div :if={s.doc} class="std-lib-doc">{s.doc}</div>
          <button type="button" class="std-lib-insert" phx-click="insert_stdlib" phx-value-id={s.id}>insert</button>
        </article>
      </div>
    </section>
    """
  end

  defp kind_badge(:inline), do: "◦ inline"
  defp kind_badge(:param), do: "▸ param"
  defp kind_badge(:function), do: "ƒ function"
end
