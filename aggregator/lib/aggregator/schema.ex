defmodule Aggregator.Schema do
  @moduledoc """
  Валидация вывода агентов по жёсткому контракту (`priv/schema.json`, JSON Schema draft 7).

  Это ворота на входе аггрегатора: всё, что приходит из артефактов агентов, проходит
  здесь до кластеризации. Невалидный вывод → агент считается «упавшим» (см. CLI-слой),
  а не молча протаскивается дальше.

  Схема резолвится один раз и кэшируется в `:persistent_term` (read-mostly, без процесса).
  """

  alias ExJsonSchema.Validator

  @schema_file "schema.json"
  @cache_key {__MODULE__, :resolved_schema}

  @typedoc "Человекочитаемые причины невалидности либо маркер битого JSON."
  @type errors :: [String.t()] | :invalid_json

  @doc """
  Провалидировать уже разобранный конверт (map со строковыми ключами).

  Возвращает `:ok` или `{:error, reasons}` со списком человекочитаемых причин.

  Не-объект на верхнем уровне (валидный JSON вида `[]`/`"x"`/`42`/`null`) — это тоже
  «невалидно по контракту», поэтому возвращается `{:error, _}`, а НЕ исключение:
  иначе `Aggregator.Artifacts.load/1` уронил бы весь разбор вместо пометки агента упавшим.
  """
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(data) when is_map(data) do
    case Validator.validate(resolved(), data) do
      :ok -> :ok
      {:error, errors} -> {:error, format(errors)}
    end
  end

  def validate(_non_object), do: {:error, ["корень должен быть JSON-объектом"]}

  @doc """
  Декодировать сырой JSON и провалидировать.

  `{:error, :invalid_json}` — если строка вообще не парсится; иначе как `validate/1`.
  """
  @spec validate_json(binary()) :: :ok | {:error, errors()}
  def validate_json(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, data} -> validate(data)
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # --- внутреннее ---

  defp resolved do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        schema = load_and_resolve()
        :persistent_term.put(@cache_key, schema)
        schema

      schema ->
        schema
    end
  end

  defp load_and_resolve do
    path()
    |> File.read!()
    |> Jason.decode!()
    |> ExJsonSchema.Schema.resolve()
  end

  defp path do
    :aggregator
    |> :code.priv_dir()
    |> Path.join(@schema_file)
  end

  defp format(errors) do
    Enum.map(errors, fn {message, path} -> "#{path}: #{message}" end)
  end
end
