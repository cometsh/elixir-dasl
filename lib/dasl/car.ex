defmodule DASL.CAR do
  use TypedStruct
  alias DASL.CAR

  typedstruct enforce: true do
    field :version, integer()
    field :roots, list(binary())
    field :blocks, %{binary() => any()}
  end

  @doc """
  Decode a binary CAR file into an Elixir struct.
  """
  @spec decode(binary()) ::
          {:ok, t()} | CAR.Decoder.header_error() | CAR.Decoder.block_error()
  def decode(binary), do: CAR.Decoder.decode(binary)
end
