defmodule DASLTest do
  use ExUnit.Case
  doctest DASL

  test "greets the world" do
    assert DASL.hello() == :world
  end
end
