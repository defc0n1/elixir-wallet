defmodule KeyPair do
  @moduledoc """
  Module for generating master public and private key
  """

  @doc """
  Generating a root seed from given mnemonic phrase
  to further ensure uniqueness of master keys.
  ## Example
      iex> KeyPair.generate_root_seed("mnemonic", "pass", [iterations: 2048, digest: :sha512])

      %{address: '177Phoj5VzFGNH7JUPLKD7pVauJEUzwEky',
      private_key: "CF92B127F1A8F2931261830CE8AA79E6E35AA2AB6E97A5FED2D5EB459744A762",
      public: "02A87C141516843F07C37EE3AE4F1C6A56E5A212076F4756F85122AE42B2FD8062"}
  """
  @spec generate_root_seed(String.t(), String.t(), List.t()) :: Map.t()
  def generate_root_seed(mnemonic, password, opts \\ []) do
    generate_master_keys(KeyGenerator.generate(mnemonic, password, opts))
  end

  def generate_master_keys(seed) do
    <<private_bin::size(256), chain_code::binary>> = seed
    private = <<private_bin::256>> |> Base.encode16()
    {public, _} = :crypto.generate_key(:ecdh, :secp256k1, private_bin)
    public_short = serialize(public)
    child_private_key_derivation(private_bin, chain_code, 1)
    child_public_key_derivation(public, chain_code, 1)
    {private, public_short, chain_code}
  end

  #CHILD KEY DERIVATION DOES NOT WORK PROPERLY

  def child_private_key_derivation(parent_private_key, parent_chain_code, index) do
    {point, _} = :crypto.generate_key(:ecdh, :secp256k1, <<parent_private_key::size(256)>>)
    point_index =
      point
      |> KeyPair.serialize()
      |> Base.decode16()
      |> elem(1)

    i = if index >= :math.pow(2, 31) do
      # TODO
    else
      :crypto.hmac(:sha512, parent_chain_code, point_index <> <<index::size(32)>>)
    end

    <<il::size(256), _::binary>> = i
    base = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

    child_private_key =  il + rem(parent_private_key, base)
  end

  def child_public_key_derivation(parent_public_key, parent_chain_code, index) do
    parent_public_key_ser =
      parent_public_key
      |> KeyPair.serialize()
      |> Base.decode16()
      |> elem(1)

    i = if index >= :math.pow(2, 31) do
      raise("Hardened child")
    else
      :crypto.hmac(:sha512,parent_chain_code, parent_public_key_ser <> <<index::size(32)>>)
    end

    <<il::size(256), _::binary>> = i
    {point, _} = :crypto.generate_key(:ecdh, :secp256k1, il)

    point_int =
      point
      |> Bits.to_binary_list()
      |> Enum.join()
      |> Integer.parse(2)
      |> elem(0)

    pub_int =
      parent_public_key
      |> Bits.to_binary_list()
      |> Enum.join
      |> Integer.parse(2)
      |> elem(0)

    child_public_key =  point_int + pub_int
  end

  def serialize(point) do
    first_half =
      point
      |> Base.encode16
      |> String.slice(2, 128)
      |> String.slice(0, 64)

    second_half =
      point
      |> Base.encode16
      |> String.slice(2, 128)
      |> String.slice(64, 64)

    {last_digit_int, _} =
      second_half
      |> String.slice(63, 63)
      |>Integer.parse(16)

    cond do
      rem(last_digit_int,2) == 0 ->
        "02" <> first_half
      rem(last_digit_int,2) != 0 ->
        "03" <> first_half
    end
  end

  def generate_wallet_address(public_key) do
    public_sha256 = :crypto.hash(:sha256,
      public_key
      |> Base.decode16()
      |> elem(1))

    public_ripemd160 =
      :crypto.hash(:ripemd160, public_sha256)
      |> Base.encode16()

    public_add_netbytes = "00" <> public_ripemd160

    public_sha256_netbytes = :crypto.hash(:sha256,
      public_add_netbytes
      |> Base.decode16()
      |> elem(1))
    public_sha256_netbytes_2 = :crypto.hash(:sha256, public_sha256_netbytes)

    slice_four_bytes =
      public_sha256_netbytes_2
      |> Base.encode16()
      |> String.slice(0..7)

    public_add_netbytes <> slice_four_bytes
    |> Base.decode16()
    |> elem(1)
    |> :base58.binary_to_base58
  end
end
