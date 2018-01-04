defmodule KeyPair do
  @moduledoc """
  Module for generating master public and private key
  """

  alias Structs.Bip32PubKey, as: PubKey
  alias Structs.Bip32PrivKey, as: PrivKey

  # Constant for generating the private_key / chain_code
  @bitcoin_key "Bitcoin seed"
  @aeternity_key "Aeternity seed"

  # Integers modulo the order of the curve (referred to as n)
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  # Used as guard for the key derivation type: normal / hardned
  @mersenne_prime 2_147_483_647

  def generate_seed(mnemonic, pass_phrase \\ "", opts \\ []) do
    SeedGenerator.generate(mnemonic, pass_phrase, opts)
  end

  @doc """
  Generates master private extended key.
  If Currency is not specified a `Bitcoin` key will be created
  ## Examples
      iex> generate_master_key(seed_bin, :seed)
      master_extended_btc_key

      iex> generate_master_key(seed_bin, :seed, :ae)
      master_extended_ae_key

  ## Currencies

     -  `:ae`  - Creates an `Aeternity` key
     -  `:btc` - Creates a `Bitcoin` key
  """
  @spec generate_master_key(Binary.t(), currency::Atom.t()) :: extended_key::Map.t()
  def generate_master_key(seed_bin, :btc) do
     build_master_key(:crypto.hmac(:sha512, @bitcoin_key, seed_bin), :btc)
  end
  def generate_master_key(seed_bin, :ae) do
     build_master_key(:crypto.hmac(:sha512, @aeternity_key, seed_bin), :ae)
  end
  def generate_master_key(_, currency) do
     IO.warn("This cryptocurrency is not supported! Check the doc for more info.")
  end

  defp build_master_key(<<priv_key::binary-32, c_code::binary>>, currency) do
    key = PrivKey.create(:mainnet, currency)
    %{key | key: priv_key, chain_code: c_code}
  end

  def to_public_key(%PrivKey{} = priv_key) do
    pub_key = KeyPair.generate_pub_key(priv_key)
    key = PubKey.create(:mainnet, priv_key.currency)
    %{key |
      depth: priv_key.depth,
      f_print: priv_key.f_print,
      child_num: priv_key.child_num,
      chain_code: priv_key.chain_code,
      key: pub_key}
  end

  def generate_pub_key(%PrivKey{key: priv_key}) do
    {pub_key, _rest} = :crypto.generate_key(:ecdh, :secp256k1, priv_key)
    pub_key
  end
  def generate_pub_key(%PrivKey{} = key, :compressed) do
    key
    |> KeyPair.generate_pub_key()
    |> KeyPair.compress()
  end

  def fingerprint(%PrivKey{} = key) do
    key
    |> KeyPair.generate_pub_key(:compressed)
    |> KeyPair.fingerprint()
  end
  def fingerprint(%PubKey{key: pub_key}) do
    pub_key
    |> KeyPair.compress()
    |> KeyPair.fingerprint()
  end
  def fingerprint(pub_key) do
    <<f_print::binary-4, _rest::binary>> =
      :crypto.hash(:ripemd160, :crypto.hash(:sha256, pub_key))
    f_print
  end

  defp serialize(%PubKey{} = key) do
    compressed_pub_key = KeyPair.compress(key.key)
    {<<key.version::size(32)>>,
     <<key.depth::size(8),
     key.f_print::binary-4,
     key.child_num::size(32),
     key.chain_code::binary,
     compressed_pub_key::binary>>}
  end
  defp serialize(%PrivKey{} = key) do
    {<<key.version::size(32)>>,
     <<key.depth::size(8),
     key.f_print::binary-4,
     key.child_num::size(32),
     key.chain_code::binary,
     <<0::size(8)>>, key.key::binary>>}
  end

  def format_key(key) when is_map(key) do
    {prefix, bip32_serialization} = serialize(key)
    Base58Check.encode58check(prefix, bip32_serialization)
  end

  def derive(key, <<"m/", path::binary>>) do ## Deriving private keys
    derive(key, path, :private)
  end
  def derive(key, <<"M/", path::binary>>) do ## Deriving public keys
    derive(key, path, :public)
  end
  defp derive(key, path, type) do
    KeyPair.derive_pathlist(
      key,
      :lists.map(fn(elem) ->
        case String.reverse(elem) do
          <<"'", hardened::binary>> ->
            {num, _rest} =
              hardened
              |> String.reverse()
              |> Integer.parse()
            num + @mersenne_prime + 1
          _ ->
            {num, _rest} = Integer.parse(elem)
            num
        end
      end, :binary.split(path, <<"/">>, [:global])),
      type)
  end

  def derive_pathlist(%PrivKey{} = key, [], :private), do: key
  def derive_pathlist(%PrivKey{} = key, [], :public), do: KeyPair.to_public_key(key)
  def derive_pathlist(%PubKey{} = key, [], :public), do: key
  def derive_pathlist(key, pathlist, type) do
    [index | rest] = pathlist
    key
    |> derive_key(index)
    |> KeyPair.derive_pathlist(rest, type)
  end

  def derive_key(%PrivKey{} = key, index) when index > -1 and index <= @mersenne_prime do
    # Normal derivation
    compressed_pub_key =
        KeyPair.generate_pub_key(key, :compressed)

    <<derived_key::size(256), child_chain::binary>> =
      :crypto.hmac(:sha512, key.chain_code,
        <<compressed_pub_key::binary, index::size(32)>>)

    <<parent_key_int::size(256)>> = key.key
    child_key = :binary.encode_unsigned(rem(derived_key + parent_key_int, @n))

    KeyPair.derive_key(key, child_key, child_chain, index)
  end

  def derive_key(%PrivKey{} = key, index) when index > @mersenne_prime do
    # Hardned derivation
    <<derived_key::size(256), child_chain::binary>> =
      :crypto.hmac(:sha512, key.chain_code,
        <<0::size(8), key.key::binary, index::size(32)>>)

    <<key_int::size(256)>> = key.key
    child_key = :binary.encode_unsigned(rem(derived_key + key_int, @n))

    KeyPair.derive_key(key, child_key, child_chain, index)
  end

  def derive_key(%PubKey{} = key, index) when index > -1 and index <= @mersenne_prime do
    # Normal derivation
    serialized_pub_key = KeyPair.compress(key.key)

    <<derived_key::binary-32, child_chain::binary>> =
      :crypto.hmac(:sha512, key.chain_code,
        <<serialized_pub_key::binary, index::size(32)>>)

    {:ok, child_key} = :libsecp256k1.ec_pubkey_tweak_add(key.key, derived_key)

    KeyPair.derive_key(key, child_key, child_chain, index)
  end

  def derive_key(%PubKey{}, index) when index > @mersenne_prime do
    # Hardned derivation
    raise(RuntimeError, "Cannot derive Public Hardened child")
  end

  def derive_key(key, child_key, child_chain, index) when is_map(key) do
    %{key |
      key: child_key,
      chain_code: child_chain,
      depth: key.depth + 1,
      f_print: KeyPair.fingerprint(key),
      child_num: index}
  end

  @doc """
  Generates wallet address from a given public key
  Network ID Bitcoin bytes:
    mainnet = "0x00"
    testnet = "0x6F"
  Network ID Aeternity bytes:
    mainnet = "0x18"
    testnet = "0x42"
  """
  @spec generate_wallet_address(Binary.t(), tuple()) :: String.t()
  def generate_wallet_address(public_key) do
    generate_address(public_key)
  end
  def generate_wallet_address(public_key, :ae) do
    generate_address(public_key, 0x18)
  end
  defp generate_address(public_key, net_bytes \\ 0x00) do
    pub_ripemd160 = :crypto.hash(:ripemd160,
      :crypto.hash(:sha256, public_key))

    pub_with_netbytes = <<net_bytes::size(8), pub_ripemd160::binary>>

    <<checksum::binary-4, _rest::binary>> = :crypto.hash(:sha256,
      :crypto.hash(:sha256, pub_with_netbytes))

    pub_with_netbytes <> checksum |> Base58Check.encode58()
  end

  defp compress(<<_prefix::size(8), x_coordinate::size(256), y_coordinate::size(256)>>) do
    prefix = case rem(y_coordinate, 2) do
      0 -> 0x02
      _ -> 0x03
    end
    <<prefix::size(8), x_coordinate::size(256)>>
  end
end
