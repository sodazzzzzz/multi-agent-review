defmodule Aggregator.CLITargetRepoTest do
  # async: false — тесты мутируют глобальное окружение (TARGET_REPO/GITHUB_REPOSITORY).
  use ExUnit.Case, async: false

  alias Aggregator.CLI

  # Сохраняем и восстанавливаем исходный GITHUB_REPOSITORY (в CI он выставлен), чтобы
  # не «протечь» в другие тесты.
  setup do
    orig = System.get_env("GITHUB_REPOSITORY")

    on_exit(fn ->
      System.delete_env("TARGET_REPO")

      case orig do
        nil -> System.delete_env("GITHUB_REPOSITORY")
        v -> System.put_env("GITHUB_REPOSITORY", v)
      end
    end)

    :ok
  end

  test "TARGET_REPO перекрывает GITHUB_REPOSITORY (центральный App → сторонний репо)" do
    System.put_env("GITHUB_REPOSITORY", "self/repo")
    System.put_env("TARGET_REPO", "other/eden")
    assert CLI.target_slug() == "other/eden"
  end

  test "нет TARGET_REPO → fallback на GITHUB_REPOSITORY (само-ревью)" do
    System.put_env("GITHUB_REPOSITORY", "self/repo")
    System.delete_env("TARGET_REPO")
    assert CLI.target_slug() == "self/repo"
  end

  test "пустой TARGET_REPO → fallback на GITHUB_REPOSITORY" do
    System.put_env("GITHUB_REPOSITORY", "self/repo")
    System.put_env("TARGET_REPO", "")
    assert CLI.target_slug() == "self/repo"
  end
end
