defmodule Aggregator.DiffTest do
  use ExUnit.Case, async: true

  alias Aggregator.Diff

  @patch """
  diff --git a/lib/a.ex b/lib/a.ex
  index 1234567..89abcde 100644
  --- a/lib/a.ex
  +++ b/lib/a.ex
  @@ -1,4 +1,5 @@
   defmodule A do
  -  def old, do: 1
  +  def new, do: 2
  +  def extra, do: 3
     # tail
   end
  diff --git a/lib/b.ex b/lib/b.ex
  new file mode 100644
  index 0000000..1111111
  --- /dev/null
  +++ b/lib/b.ex
  @@ -0,0 +1,2 @@
  +defmodule B do
  +end
  """

  describe "right_lines/1" do
    test "контекст и добавленные строки получают RIGHT-номера, удалённые — нет" do
      idx = Diff.right_lines(@patch)
      assert MapSet.equal?(idx["lib/a.ex"], MapSet.new([1, 2, 3, 4, 5]))
    end

    test "новый файл (@@ -0,0 +1,2 @@) индексируется с первой строки" do
      idx = Diff.right_lines(@patch)
      assert MapSet.equal?(idx["lib/b.ex"], MapSet.new([1, 2]))
    end

    test "пустой дифф → пустой индекс" do
      assert Diff.right_lines("") == %{}
    end
  end

  describe "in_hunk?/3" do
    setup do
      %{idx: Diff.right_lines(@patch)}
    end

    test "добавленная строка — в хунке", %{idx: idx} do
      assert Diff.in_hunk?(idx, "lib/a.ex", 2)
      assert Diff.in_hunk?(idx, "lib/a.ex", 3)
    end

    test "контекстная строка — в хунке", %{idx: idx} do
      assert Diff.in_hunk?(idx, "lib/a.ex", 1)
      assert Diff.in_hunk?(idx, "lib/a.ex", 5)
    end

    test "строка за пределами хунка — нет", %{idx: idx} do
      refute Diff.in_hunk?(idx, "lib/a.ex", 6)
    end

    test "неизвестный файл и nil-строка — нет", %{idx: idx} do
      refute Diff.in_hunk?(idx, "lib/zzz.ex", 1)
      refute Diff.in_hunk?(idx, "lib/a.ex", nil)
    end
  end
end
