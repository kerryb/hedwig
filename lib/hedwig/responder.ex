defmodule Hedwig.Responder do
  @moduledoc ~S"""
  Base module for building responders.

  A responder is a module which setups up handlers for hearing and responding
  to incoming messages.

  ## Hearing & Responding

  Hedwig can hear messages said in a room or respond to messages directly
  addressed to it. Both methods take a regular expression, the message and a block
  to execute when there is a match. For example:

      hear ~r/(hi|hello)/i, msg do
        # your code here
      end

      respond ~r/help$/i, msg do
        # your code here
      end

  ## Using captures

  Responders support regular expression captures. It supports both normal
  captures and named captures. When a message matches, captures are handled
  automatically and added to the message's `:matches` key.

  Accessing the captures depends on the type of capture used in the responder's
  regex. If named captures are used, captures will be available by the name,
  otherwise it will be available by an index, starting with 0.


  ### Example:

      # with indexed captures
      hear ~r/i like (\w+), msg do
        emote msg, "likes #{msg.matches[1]} too!"
      end

      # with named captures
      hear ~r/i like (?<subject>\w+), msg do
        emote msg, "likes #{msg.matches["subject"]} too!"
      end
  """

  defmacro __using__(_opts) do
    quote do
      import unquote(__MODULE__)
      import Kernel, except: [send: 2]

      Module.register_attribute(__MODULE__, :hear, accumulate: true)
      Module.register_attribute(__MODULE__, :respond, accumulate: true)
      Module.register_attribute(__MODULE__, :usage, accumulate: true)

      @before_compile unquote(__MODULE__)
    end
  end

  @doc """
  Sends a message via the underlying adapter.

  ## Example

      send msg, "Hello there!"
  """
  def send(%Hedwig.Message{robot: %{pid: pid}} = msg, text) do
    Hedwig.Robot.send(pid, %{msg | text: text})
  end

  @doc """
  Send a reply message via the underlying adapter.

  ## Example

      reply msg, "Hello there!"
  """
  def reply(%Hedwig.Message{robot: %{pid: pid}} = msg, text) do
    Hedwig.Robot.reply(pid, %{msg | text: text})
  end

  @doc """
  Send an emote message via the underlying adapter.

  ## Example

      emote msg, "goes and hides"
  """
  def emote(%Hedwig.Message{robot: %{pid: pid}} = msg, text) do
    Hedwig.Robot.emote(pid, %{msg | text: text})
  end

  @doc """
  Returns a random item from a list or range.

  ## Example

      send msg, random(["apples", "bananas", "carrots"])
  """
  def random(list) do
    :rand.seed(:exsplus, :os.timestamp())
    Enum.random(list)
  end

  @doc false
  def run(msg, responders) do
    Enum.map(responders, &run_async(msg, &1))
  end

  defp run_async(%{text: text} = msg, {regex, mod, fun, opts}) do
    Task.async(fn ->
      if Regex.match?(regex, text) do
        msg = %{msg | matches: find_matches(regex, text)}
        apply(mod, fun, [msg, opts])
      else
        nil
      end
    end)
  end

  defp find_matches(regex, text) do
    case Regex.names(regex) do
      [] ->
        matches = Regex.run(regex, text)

        Enum.reduce(Enum.with_index(matches), %{}, fn {match, index}, acc ->
          Map.put(acc, index, match)
        end)

      _ ->
        Regex.named_captures(regex, text)
    end
  end

  @doc """
  Matches messages based on the regular expression.

  ## Example

      hear ~r/hello/, msg do
        # code to handle the message
      end
  """
  defmacro hear(regex, msg, opts \\ Macro.escape(%{}), do: block) do
    name = unique_name(:hear)

    quote do
      @hear {unquote(regex), unquote(name)}
      @doc false
      def unquote(name)(unquote(msg), unquote(opts)) do
        unquote(block)
      end
    end
  end

  @doc """
  Setups up an responder that will match when a message is prefixed with the bot's name.

  ## Example

      # Give our bot's name is "alfred", this responder
      # would match for a message with the following text:
      # "alfred hello"
      respond ~r/hello/, msg do
        # code to handle the message
      end
  """
  defmacro respond(regex, msg, opts \\ Macro.escape(%{}), do: block) do
    name = unique_name(:respond)

    quote do
      @respond {unquote(regex), unquote(name)}
      @doc false
      def unquote(name)(unquote(msg), unquote(opts)) do
        unquote(block)
      end
    end
  end

  defp unique_name(type) do
    String.to_atom("#{type}_#{System.unique_integer([:positive, :monotonic])}")
  end

  @doc false
  def respond_pattern(pattern, robot) do
    pattern
    |> Regex.source()
    |> rewrite_source(robot.name, robot.aka)
    |> Regex.compile!(Regex.opts(pattern))
  end

  defp rewrite_source(source, name, nil) do
    "^\\s*[@]?#{name}[:,]?\\s*(?:#{source})"
  end

  defp rewrite_source(source, name, aka) do
    [a, b] = if String.length(name) > String.length(aka), do: [name, aka], else: [aka, name]
    "^\\s*[@]?(?:#{a}[:,]?|#{b}[:,]?)\\s*(?:#{source})"
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def usage(name) do
        @usage
        |> Enum.map(&String.strip/1)
        |> Enum.map(&String.replace(&1, "hedwig", name))
      end

      def __hearers__ do
        @hear
      end

      def __responders__ do
        @respond
      end

      @doc false
      def install(robot, opts) do
        hearers =
          __hearers__()
          |> Enum.map(&install_hearer(&1, robot, opts))
          |> Enum.map(&Task.await/1)

        responders =
          __responders__()
          |> Enum.map(&install_responder(&1, robot, opts))
          |> Enum.map(&Task.await/1)

        List.flatten([hearers, responders])
      end

      defp install_hearer({regex, fun}, _robot, opts) do
        Task.async(fn ->
          {regex, __MODULE__, fun, Enum.into(opts, %{})}
        end)
      end

      defp install_responder({regex, fun}, robot, opts) do
        Task.async(fn ->
          regex = Hedwig.Responder.respond_pattern(regex, robot)
          {regex, __MODULE__, fun, Enum.into(opts, %{})}
        end)
      end
    end
  end
end
