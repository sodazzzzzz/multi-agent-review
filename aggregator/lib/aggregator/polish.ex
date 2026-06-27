defmodule Aggregator.Polish do
  @moduledoc """
  Кодовая «заморозка фактов» при причёсывании прозы.

  Все цифры — `severity`, `consensus`, `line`, `file` — посчитаны и заморожены
  ещё в `Aggregator.Cluster`. Модель-причёсыватель имеет право улучшить ТОЛЬКО
  человекочитаемый текст замечания, больше ничего. Гарантию даёт не промпт, а
  этот код.

  `merge/2` берёт сырые правки модели (уже разобранный JSON) и принимает лишь те,
  что:

    1. ссылаются на существующий `cluster.id`;
    2. дают непустой текст;
    3. не противоречат замороженным инвариантам — если модель «эхом» вернула
       `severity`/`line`/`file`/`consensus`, они обязаны совпасть; расхождение =
       модель спутала кластер → правка отвергается.

  Возвращается карта `id => одобренный текст`. Всё неодобренное просто
  отсутствует — выше по стеку (`Aggregator.Render`) для таких кластеров берётся
  детерминированный текст. Так причёсывание не может протащить искажение фактов.

  Сам вызов модели (шелл к Claude) живёт в эффект-слое (CLI): он лишь строит
  список `rewrite()` и передаёт сюда. Freeze-логика остаётся чистой и тестируемой
  без сети.
  """

  alias Aggregator.Cluster

  @typedoc """
  Сырая правка от модели (map со строковыми ключами, как из `Jason.decode/1`).

  Обязателен `"id"` и `"message"`; ключи `"severity"`/`"line"`/`"file"`/
  `"consensus"` — необязательное «эхо» для сверки.
  """
  @type rewrite :: %{optional(String.t()) => term()}

  @typedoc "Итог слияния: одобренные тексты по id + счётчики для логов/summary."
  @type result :: %{
          overrides: %{optional(pos_integer()) => String.t()},
          applied: non_neg_integer(),
          rejected: non_neg_integer()
        }

  @doc """
  Слить правки модели с замороженными кластерами.

  Чистая функция: ничего не мутирует, сеть не трогает. См. моду́ль про контракт.
  """
  @spec merge([Cluster.t()], [rewrite()]) :: result()
  def merge(clusters, rewrites) when is_list(clusters) and is_list(rewrites) do
    index = Map.new(clusters, &{&1.id, &1})

    {overrides, rejected} =
      Enum.reduce(rewrites, {%{}, 0}, fn rewrite, {acc, rej} ->
        case approve(rewrite, index) do
          {:ok, id, message} -> {Map.put(acc, id, message), rej}
          :reject -> {acc, rej + 1}
        end
      end)

    %{overrides: overrides, applied: map_size(overrides), rejected: rejected}
  end

  # --- внутреннее ---

  defp approve(rewrite, index) when is_map(rewrite) do
    with {:ok, id} <- fetch_id(rewrite),
         {:ok, cluster} <- Map.fetch(index, id),
         {:ok, message} <- fetch_message(rewrite),
         :ok <- frozen?(rewrite, cluster) do
      {:ok, id, message}
    else
      _ -> :reject
    end
  end

  defp approve(_non_map, _index), do: :reject

  defp fetch_id(%{"id" => id}) when is_integer(id) and id > 0, do: {:ok, id}
  defp fetch_id(_), do: :error

  defp fetch_message(%{"message" => message}) when is_binary(message) do
    case String.trim(message) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp fetch_message(_), do: :error

  # Эхо-инварианты: отсутствующий ключ нечего сверять (ок), присутствующий —
  # обязан совпасть с замороженным значением кластера.
  defp frozen?(rewrite, %Cluster{} = c) do
    if echo_ok?(rewrite, "severity", c.severity) and
         echo_ok?(rewrite, "line", c.line) and
         echo_ok?(rewrite, "file", c.file) and
         echo_ok?(rewrite, "consensus", c.consensus),
       do: :ok,
       else: :error
  end

  defp echo_ok?(rewrite, key, frozen) do
    case Map.fetch(rewrite, key) do
      :error -> true
      {:ok, ^frozen} -> true
      {:ok, _other} -> false
    end
  end
end
