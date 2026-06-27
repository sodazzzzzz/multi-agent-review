defmodule Aggregator.Finding do
  @moduledoc """
  Единичное замечание от одного агента — нормализованное к жёсткому контракту.

  Это чистая структура данных: никакой сети, процессов или эффектов.
  Парсинг JSON-артефактов и валидация по схеме живут выше (в CLI-слое),
  сюда приходят уже разобранные и провалидированные findings.
  """

  @type severity :: String.t()
  @type t :: %__MODULE__{
          agent: String.t(),
          file: String.t(),
          line: pos_integer() | nil,
          severity: severity(),
          category: String.t() | nil,
          message: String.t() | nil,
          suggestion: String.t() | nil
        }

  @enforce_keys [:agent, :file, :severity]
  defstruct [:agent, :file, :line, :severity, :category, :message, :suggestion]

  @doc """
  Собрать `Finding` из map'а с **строковыми** ключами (как отдаёт `Jason.decode/1`).

  Лишние ключи игнорируются; отсутствующие опциональные поля → `nil`.
  Обязательные `agent`/`file`/`severity` должны присутствовать.
  """
  @spec from_map(map()) :: t()
  def from_map(%{"agent" => agent, "file" => file, "severity" => severity} = m) do
    %__MODULE__{
      agent: agent,
      file: file,
      line: m["line"],
      severity: severity,
      category: m["category"],
      message: m["message"],
      suggestion: m["suggestion"]
    }
  end
end
