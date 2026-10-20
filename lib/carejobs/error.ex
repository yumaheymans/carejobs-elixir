defmodule CareJobs.Error do
  @moduledoc """
  Every failure of the client, returned as `{:error, %CareJobs.Error{}}`.

  `:code` says where the failure came from:

    * `:tool` - the server ran the tool and answered with an error (an unknown kind, an
      unknown employer). `:message` is the server's own explanation.
    * `:rpc` - a JSON-RPC error (`:rpc_code` is set).
    * `:http` - a non-2xx HTTP status (`:status` is set).
    * `:network` - the request never completed: DNS, a refused connection, a TLS failure.
    * `:timeout` - no answer within the `:timeout` option.
    * `:protocol` - the answer was not the shape the MCP protocol promises, or the
      arguments could not be encoded as JSON.

  `:tool` holds the name of the tool that was called, when there was one.

  The struct is an exception, so it also works with `raise/1`:

      case CareJobs.employer("no-such-employer") do
        {:ok, %{data: employer}} -> employer
        {:error, %CareJobs.Error{code: :tool} = error} -> raise error
      end

  ## Examples

      iex> error = %CareJobs.Error{code: :tool, message: "Unknown employer 'x'."}
      iex> Exception.message(error)
      "Unknown employer 'x'."
  """

  @type code :: :tool | :rpc | :http | :network | :timeout | :protocol

  @type t :: %__MODULE__{
          __exception__: true,
          code: code(),
          message: String.t(),
          status: non_neg_integer() | nil,
          tool: String.t() | nil,
          rpc_code: integer() | nil
        }

  defexception [:code, :status, :tool, :rpc_code, message: "CareJobs request failed"]

  @doc false
  @spec new(code(), String.t(), keyword()) :: t()
  def new(code, message, fields \\ []) when is_atom(code) and is_binary(message) do
    struct!(__MODULE__, [code: code, message: message] ++ fields)
  end
end
