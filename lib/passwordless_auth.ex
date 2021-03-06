defmodule PasswordlessAuth do
  @moduledoc """
  PasswordlessAuth is a library gives you the ability to verify a user's
  phone number by sending them a verification code, and verifying that
  the code they provide matches the code that was sent to their phone number.

  Verification codes are stored in an Agent along with the phone number they
  were sent to. They are stored with an expiration date/time.

  A garbage collector removes expires verification codes from the store.
  See PasswordlessAuth.GarbageCollector
  """
  use Application
  alias PasswordlessAuth.{GarbageCollector, VerificationCode, Store}

  @default_verification_code_ttl 300
  @twilio_adapter Application.get_env(:passwordless_auth, :twilio_adapter) || ExTwilio

  @doc false
  def start(_type, _args) do
    children = [
      GarbageCollector,
      Store
    ]

    opts = [strategy: :one_for_one, name: PasswordlessAuth.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @doc """
  Send an SMS with a verification code to the given `phone_number`

  The verification code is valid for the number of seconds given to the
  `verification_code_ttl` config option (defaults to 300)

  Options for the Twilio request can be passed to `opts[:twilio_request_options`.
  You'll need to pass at least a `from` or `messaging_service_sid` option
  to `options[:twilio_request_options]` for messages to be sent
  (see the [Twilio API documentation](https://www.twilio.com/docs/api/messaging/send-messages#conditional-parameters))
  For example:

  Arguments:

  - `phone_number`: The phone number that will receive the text message
  - `opts`: Options (see below)

  Options:
  
  - `message`: A custom text message template. The verification code
  can be injected with this formatting: _"Yarrr, {{code}} be the secret"_.
  Defaults to _"Your verification code is: {{code}}"_
  - `code_length`: Length of the verification code (defaults to 6)
  - `twilio_request_options`: A map of options that are passed to the Twilio request
  (see the [Twilio API documentation](https://www.twilio.com/docs/api/messaging/send-messages#conditional-parameters))

  Returns `{:ok, twilio_response}` or `{:error, error}`.
  """
  @spec create_and_send_verification_code(String.t(), list()) :: {:ok, struct()} | {:error, String.t()}
  def create_and_send_verification_code(phone_number, opts \\ []) do
    message = opts[:message] || "Your verification code is: {{code}}"
    code_length = opts[:code_length] || 6
    code = VerificationCode.generate_code(code_length)

    ttl =
      Application.get_env(:passwordless_auth, :verification_code_ttl) ||
        @default_verification_code_ttl

    expires = NaiveDateTime.utc_now() |> NaiveDateTime.add(ttl)

    twilio_request_options = opts[:twilio_request_options] || []
    request =
      Enum.into(twilio_request_options, %{
        to: phone_number,
        body: String.replace(message, "{{code}}", code)
      })

    case @twilio_adapter.Message.create(request) do
      {:ok, response} ->
        Agent.update(
          Store,
          &Map.put(&1, phone_number, %VerificationCode{
            code: code,
            expires: expires
          })
        )

        {:ok, response}

      {:error, message, _code} ->
        {:error, message}
    end
  end

  @doc """
  Verifies that a the given `phone_number` has the
  given `verification_code` stores in state and that
  the verification code hasn't expired.

  Returns `true` or `false`.

  ## Examples

      iex> PasswordlessAuth.verify_code("+447123456789", "123456")
      false

  """
  @spec verify_code(String.t(), String.t()) :: boolean()
  def verify_code(phone_number, verification_code) do
    current_date_time = NaiveDateTime.utc_now()

    with state <- Agent.get(Store, fn state -> state end),
         true <- Map.has_key?(state, phone_number),
         ^verification_code <- get_in(state, [phone_number, Access.key(:code)]),
         :gt <-
           NaiveDateTime.compare(
             get_in(state, [phone_number, Access.key(:expires)]),
             current_date_time
           ) do
      true
    else
      _ -> false
    end
  end

  @doc """
  Removes a code from state based on the given `phone_number`

  Returns `{:ok, %VerificationCode{...}}` or `{:error, :reason}`.
  """
  @spec remove_code(String.t()) :: {:ok, %VerificationCode{}} | {:error, atom()}
  def remove_code(phone_number) do
    state = Agent.get(Store, fn state -> state end)

    if Map.has_key?(state, phone_number) do
      code = Agent.get(Store, &Map.get(&1, phone_number))
      Agent.update(Store, &Map.delete(&1, phone_number))
      {:ok, code}
    else
      {:error, :does_not_exist}
    end
  end
end
