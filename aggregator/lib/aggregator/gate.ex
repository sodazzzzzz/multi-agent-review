defmodule Aggregator.Gate do
  @moduledoc """
  Чистое решение «блокировать merge или нет» по кластерам и режиму `fail_on`.

  Продукт по умолчанию **advisory**: `:none` → никогда не блокирует. Блокировка —
  opt-in. Это единственный источник exit-кода для CLI; вся политика — здесь,
  без сети и процессов.
  """

  alias Aggregator.Cluster

  @type mode :: :none | :p0 | :consensus_p0
  @type decision :: {:pass | :block, String.t()}

  @doc """
  Разобрать строковый input `fail_on` в режим.

  Неизвестное/`nil` → `:none` (advisory) — безопасный дефолт.
  """
  @spec parse_mode(String.t() | nil) :: mode()
  def parse_mode("p0"), do: :p0
  def parse_mode("consensus-p0"), do: :consensus_p0
  def parse_mode(_other), do: :none

  @doc """
  Решение по кластерам и режиму.

    * `:none` — всегда `:pass` (advisory).
    * `:p0` — `:block`, если есть кластер severity `P0`.
    * `:consensus_p0` — `:block`, если есть `P0`-кластер с консенсусом ≥ 2.
  """
  @spec decide([Cluster.t()], mode()) :: decision()
  def decide(_clusters, :none), do: {:pass, "advisory — блокировка отключена (fail_on: none)"}

  def decide(clusters, :p0) do
    if Enum.any?(clusters, &(&1.severity == "P0")),
      do: {:block, "найден блокирующий P0"},
      else: {:pass, "P0 не найден"}
  end

  def decide(clusters, :consensus_p0) do
    if Enum.any?(clusters, &(&1.severity == "P0" and &1.consensus >= 2)),
      do: {:block, "найден P0 с консенсусом ≥ 2 моделей"},
      else: {:pass, "нет P0 с консенсусом ≥ 2"}
  end

  @doc "Exit-код для CLI: 0 = pass, 1 = block."
  @spec exit_code(decision()) :: 0 | 1
  def exit_code({:pass, _reason}), do: 0
  def exit_code({:block, _reason}), do: 1
end
