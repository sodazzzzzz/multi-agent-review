defmodule Aggregator do
  @moduledoc """
  Детерминированный «мозг» мульти-агентного PR-ревью-бота.

  Слои:

    * чистые — `Aggregator.Finding`, `Aggregator.Cluster`, `Aggregator.Consensus`:
      принимают данные, возвращают данные. Источник истины по findings/severity.
    * эффекты (добавляются позже) — чтение артефактов, валидация по схеме,
      Claude-причёсывание прозы, постинг в GitHub Pulls API, exit-код.

  Инвариант: после стадии кластеризации findings и все цифры заморожены.
  Модель-причёсыватель меняет только текст `message`, не факты.
  """
end
