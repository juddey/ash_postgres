defmodule AshPostgres.Expr do
  @moduledoc false

  alias Ash.Filter
  alias Ash.Query.{BooleanExpression, Exists, Not, Ref}
  alias Ash.Query.Operator.IsNil
  alias Ash.Query.Function.{Ago, Contains, GetPath, If, Length, Now, Type}
  alias AshPostgres.Functions.{Fragment, TrigramSimilarity}

  require Ecto.Query

  def dynamic_expr(query, expr, bindings, embedded? \\ false, type \\ nil)

  def dynamic_expr(query, %Filter{expression: expression}, bindings, embedded?, type) do
    dynamic_expr(query, expression, bindings, embedded?, type)
  end

  # A nil filter means "everything"
  def dynamic_expr(_, nil, _, _, _), do: true
  # A true filter means "everything"
  def dynamic_expr(_, true, _, _, _), do: true
  # A false filter means "nothing"
  def dynamic_expr(_, false, _, _, _), do: false

  def dynamic_expr(query, expression, bindings, embedded?, type) do
    do_dynamic_expr(query, expression, bindings, embedded?, type)
  end

  defp do_dynamic_expr(query, expr, bindings, embedded?, type \\ nil)

  defp do_dynamic_expr(_, {:embed, other}, _bindings, _true, _type) do
    other
  end

  defp do_dynamic_expr(query, %Not{expression: expression}, bindings, embedded?, _type) do
    new_expression = do_dynamic_expr(query, expression, bindings, embedded?)
    Ecto.Query.dynamic(not (^new_expression))
  end

  defp do_dynamic_expr(
         query,
         %TrigramSimilarity{arguments: [arg1, arg2], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    arg1 = do_dynamic_expr(query, arg1, bindings, pred_embedded? || embedded?)
    arg2 = do_dynamic_expr(query, arg2, bindings, pred_embedded? || embedded?)

    Ecto.Query.dynamic(fragment("similarity(?, ?)", ^arg1, ^arg2))
    |> maybe_type(type, query)
  end

  defp do_dynamic_expr(
         query,
         %IsNil{left: left, right: right, embedded?: pred_embedded?},
         bindings,
         embedded?,
         _type
       ) do
    left_expr = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?)
    right_expr = do_dynamic_expr(query, right, bindings, pred_embedded? || embedded?)
    Ecto.Query.dynamic(is_nil(^left_expr) == ^right_expr)
  end

  defp do_dynamic_expr(
         _query,
         %Ago{arguments: [left, right], embedded?: _pred_embedded?},
         _bindings,
         _embedded?,
         _type
       )
       when is_integer(left) and (is_binary(right) or is_atom(right)) do
    Ecto.Query.dynamic(datetime_add(^DateTime.utc_now(), ^left * -1, ^to_string(right)))
  end

  defp do_dynamic_expr(
         query,
         %GetPath{
           arguments: [%Ref{attribute: %{type: type}}, right]
         } = get_path,
         bindings,
         embedded?,
         nil
       )
       when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)
      do_get_path(query, get_path, bindings, embedded?, type)
    else
      do_get_path(query, get_path, bindings, embedded?)
    end
  end

  defp do_dynamic_expr(
         query,
         %GetPath{
           arguments: [%Ref{attribute: %{type: {:array, type}}}, right]
         } = get_path,
         bindings,
         embedded?,
         nil
       )
       when is_atom(type) and is_list(right) do
    if Ash.Type.embedded_type?(type) do
      type = determine_type_at_path(type, right)
      do_get_path(query, get_path, bindings, embedded?, type)
    else
      do_get_path(query, get_path, bindings, embedded?)
    end
  end

  defp do_dynamic_expr(
         query,
         %GetPath{} = get_path,
         bindings,
         embedded?,
         type
       ) do
    do_get_path(query, get_path, bindings, embedded?, type)
  end

  defp do_dynamic_expr(
         query,
         %Contains{arguments: [left, %Ash.CiString{} = right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    if "citext" in AshPostgres.DataLayer.Info.repo(query.__ash_bindings__.resource).installed_extensions() do
      do_dynamic_expr(
        query,
        %Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "strpos((",
            expr: left,
            raw: "::citext), (",
            expr: right,
            raw: ")) > 0"
          ]
        },
        bindings,
        embedded?,
        type
      )
    else
      do_dynamic_expr(
        query,
        %Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "strpos(lower(",
            expr: left,
            raw: "), lower(",
            expr: right,
            raw: ")) > 0"
          ]
        },
        bindings,
        embedded?,
        type
      )
    end
  end

  defp do_dynamic_expr(
         query,
         %Contains{arguments: [left, right], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: pred_embedded?,
        arguments: [
          raw: "strpos((",
          expr: left,
          raw: "), (",
          expr: right,
          raw: ")) > 0"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Length{arguments: [list], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: pred_embedded?,
        arguments: [
          raw: "array_length((",
          expr: list,
          raw: "), 1)"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %If{arguments: [condition, when_true, when_false], embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    [condition_type, when_true_type, when_false_type] =
      case AshPostgres.Types.determine_types(If, [condition, when_true, when_false]) do
        [condition_type, when_true] ->
          [condition_type, when_true, nil]

        [condition_type, when_true, when_false] ->
          [condition_type, when_true, when_false]
      end
      |> Enum.map(fn type ->
        if type == :any || type == {:in, :any} do
          nil
        else
          type
        end
      end)
      |> case do
        [condition_type, nil, nil] ->
          [condition_type, type, type]

        [condition_type, when_true, nil] ->
          [condition_type, when_true, type]

        [condition_type, nil, when_false] ->
          [condition_type, type, when_false]

        [condition_type, when_true, when_false] ->
          [condition_type, when_true, when_false]
      end

    condition =
      do_dynamic_expr(query, condition, bindings, pred_embedded? || embedded?, condition_type)

    when_true =
      do_dynamic_expr(query, when_true, bindings, pred_embedded? || embedded?, when_true_type)

    when_false =
      do_dynamic_expr(
        query,
        when_false,
        bindings,
        pred_embedded? || embedded?,
        when_false_type
      )

    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: pred_embedded?,
        arguments: [
          raw: "(CASE WHEN ",
          casted_expr: condition,
          raw: " THEN ",
          casted_expr: when_true,
          raw: " ELSE ",
          casted_expr: when_false,
          raw: " END)"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  # Sorry :(
  # This is bad to do, but is the only reasonable way I could find.
  defp do_dynamic_expr(
         query,
         %Fragment{arguments: arguments, embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    arguments =
      case arguments do
        [{:raw, _} | _] ->
          arguments

        arguments ->
          [{:raw, ""} | arguments]
      end

    arguments =
      case List.last(arguments) do
        nil ->
          arguments

        {:raw, _} ->
          arguments

        _ ->
          arguments ++ [{:raw, ""}]
      end

    {params, fragment_data, _} =
      Enum.reduce(arguments, {[], [], 0}, fn
        {:raw, str}, {params, fragment_data, count} ->
          {params, [{:raw, str} | fragment_data], count}

        {:casted_expr, dynamic}, {params, fragment_data, count} ->
          {[{dynamic, :any} | params], [{:expr, {:^, [], [count]}} | fragment_data], count + 1}

        {:expr, expr}, {params, fragment_data, count} ->
          dynamic = do_dynamic_expr(query, expr, bindings, pred_embedded? || embedded?)

          {[{dynamic, :any} | params], [{:expr, {:^, [], [count]}} | fragment_data], count + 1}
      end)

    frag_dynamic = %Ecto.Query.DynamicExpr{
      fun: fn _query ->
        {{:fragment, [], Enum.reverse(fragment_data)}, Enum.reverse(params), [], %{}}
      end,
      binding: [],
      file: __ENV__.file,
      line: __ENV__.line
    }

    if type do
      Ecto.Query.dynamic(type(^frag_dynamic, ^type))
    else
      frag_dynamic
    end
  end

  defp do_dynamic_expr(
         query,
         %BooleanExpression{op: op, left: left, right: right},
         bindings,
         embedded?,
         _type
       ) do
    left_expr = do_dynamic_expr(query, left, bindings, embedded?)
    right_expr = do_dynamic_expr(query, right, bindings, embedded?)

    case op do
      :and ->
        Ecto.Query.dynamic(^left_expr and ^right_expr)

      :or ->
        Ecto.Query.dynamic(^left_expr or ^right_expr)
    end
  end

  defp do_dynamic_expr(
         query,
         %mod{
           __predicate__?: _,
           left: left,
           right: right,
           embedded?: pred_embedded?,
           operator: operator
         },
         bindings,
         embedded?,
         type
       ) do
    [left_type, right_type] =
      mod
      |> AshPostgres.Types.determine_types([left, right])
      |> Enum.map(fn type ->
        if type == :any || type == {:in, :any} do
          nil
        else
          type
        end
      end)

    left_expr = do_dynamic_expr(query, left, bindings, pred_embedded? || embedded?, left_type)

    right_expr = do_dynamic_expr(query, right, bindings, pred_embedded? || embedded?, right_type)

    case operator do
      :== ->
        Ecto.Query.dynamic(^left_expr == ^right_expr)

      :!= ->
        Ecto.Query.dynamic(^left_expr != ^right_expr)

      :> ->
        Ecto.Query.dynamic(^left_expr > ^right_expr)

      :< ->
        Ecto.Query.dynamic(^left_expr < ^right_expr)

      :>= ->
        Ecto.Query.dynamic(^left_expr >= ^right_expr)

      :<= ->
        Ecto.Query.dynamic(^left_expr <= ^right_expr)

      :in ->
        Ecto.Query.dynamic(^left_expr in ^right_expr)

      :+ ->
        Ecto.Query.dynamic(^left_expr + ^right_expr)

      :- ->
        Ecto.Query.dynamic(^left_expr - ^right_expr)

      :/ ->
        if float_type?(type) do
          Ecto.Query.dynamic(type(^left_expr, ^type) / type(^right_expr, ^type))
        else
          Ecto.Query.dynamic(^left_expr / ^right_expr)
        end

      :* ->
        Ecto.Query.dynamic(^left_expr * ^right_expr)

      :<> ->
        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "(",
              casted_expr: left_expr,
              raw: " || ",
              casted_expr: right_expr,
              raw: ")"
            ]
          },
          bindings,
          embedded?,
          type
        )

      :|| ->
        require_ash_functions!(query)

        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "ash_elixir_or(",
              casted_expr: left_expr,
              raw: ", ",
              casted_expr: right_expr,
              raw: ")"
            ]
          },
          bindings,
          embedded?,
          type
        )

      :&& ->
        require_ash_functions!(query)

        do_dynamic_expr(
          query,
          %Fragment{
            embedded?: pred_embedded?,
            arguments: [
              raw: "ash_elixir_and(",
              casted_expr: left_expr,
              raw: ", ",
              casted_expr: right_expr,
              raw: ")"
            ]
          },
          bindings,
          embedded?,
          type
        )

      other ->
        raise "Operator not implemented #{other}"
    end
  end

  defp do_dynamic_expr(query, %MapSet{} = mapset, bindings, embedded?, type) do
    do_dynamic_expr(query, Enum.to_list(mapset), bindings, embedded?, type)
  end

  defp do_dynamic_expr(
         query,
         %Ash.CiString{string: string} = expression,
         bindings,
         embedded?,
         type
       ) do
    string = do_dynamic_expr(query, string, bindings, embedded?)

    require_extension!(query, "citext", expression)

    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: embedded?,
        arguments: [
          raw: "",
          casted_expr: string,
          raw: "::citext"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Ref{
           attribute: %Ash.Query.Calculation{} = calculation,
           relationship_path: [],
           resource: resource
         } = type_expr,
         bindings,
         embedded?,
         _type
       ) do
    calculation = %{calculation | load: calculation.name}
    type = AshPostgres.Types.parameterized_type(calculation.type, [])
    validate_type!(query, type, type_expr)

    case Ash.Filter.hydrate_refs(
           calculation.module.expression(calculation.opts, calculation.context),
           %{
             resource: resource,
             aggregates: %{},
             calculations: %{},
             public?: false
           }
         ) do
      {:ok, expression} ->
        expr =
          do_dynamic_expr(
            query,
            expression,
            bindings,
            embedded?,
            type
          )

        Ecto.Query.dynamic(type(^expr, ^type))

      {:error, _error} ->
        raise "Failed to hydrate references in #{inspect(calculation.module.expression(calculation.opts, calculation.context))}"
    end
  end

  defp do_dynamic_expr(
         query,
         %Ref{attribute: %Ash.Query.Aggregate{} = aggregate} = ref,
         bindings,
         _embedded?,
         _type
       ) do
    ref_binding = ref_binding(ref, bindings)

    if is_nil(ref_binding) do
      raise "Error while building reference: #{inspect(ref)}"
    end

    expr = Ecto.Query.dynamic(field(as(^ref_binding), ^aggregate.name))

    type = AshPostgres.Types.parameterized_type(aggregate.type, aggregate.constraints)
    validate_type!(query, type, ref)

    type =
      if type && aggregate.kind == :list do
        {:array, type}
      else
        type
      end

    coalesced =
      if aggregate.default_value do
        if type do
          Ecto.Query.dynamic(coalesce(^expr, type(^aggregate.default_value, ^type)))
        else
          Ecto.Query.dynamic(coalesce(^expr, ^aggregate.default_value))
        end
      else
        expr
      end

    if type do
      Ecto.Query.dynamic(type(^coalesced, ^type))
    else
      coalesced
    end
  end

  defp do_dynamic_expr(
         query,
         %Ref{
           attribute: %Ash.Query.Calculation{} = calculation,
           relationship_path: relationship_path
         } = ref,
         bindings,
         embedded?,
         _type
       ) do
    binding_to_replace =
      Enum.find_value(bindings.bindings, fn {i, binding} ->
        if binding.path == relationship_path do
          i
        end
      end)

    temp_bindings =
      bindings.bindings
      |> Map.delete(0)
      |> Map.update!(binding_to_replace, &Map.merge(&1, %{path: [], type: :root}))

    type = AshPostgres.Types.parameterized_type(calculation.type, [])

    validate_type!(query, type, ref)

    case Ash.Filter.hydrate_refs(
           calculation.module.expression(calculation.opts, calculation.context),
           %{
             resource: ref.resource,
             aggregates: %{},
             calculations: %{},
             public?: false
           }
         ) do
      {:ok, hydrated} ->
        expr =
          do_dynamic_expr(
            query,
            Ash.Filter.update_aggregates(hydrated, fn aggregate, _ ->
              %{aggregate | relationship_path: []}
            end),
            %{bindings | bindings: temp_bindings},
            embedded?,
            type
          )

        Ecto.Query.dynamic(type(^expr, ^type))

      _ ->
        raise "Failed to hydrate references in #{inspect(calculation.module.expression(calculation.opts, calculation.context))}"
    end
  end

  defp do_dynamic_expr(
         query,
         %Type{arguments: [arg1, arg2, constraints]},
         bindings,
         embedded?,
         _type
       ) do
    arg2 = Ash.Type.get_type(arg2)
    arg1 = maybe_uuid_to_binary(arg2, arg1, arg1)
    type = AshPostgres.Types.parameterized_type(arg2, constraints)
    do_dynamic_expr(query, arg1, bindings, embedded?, type)
  end

  defp do_dynamic_expr(
         query,
         %Now{embedded?: pred_embedded?},
         bindings,
         embedded?,
         type
       ) do
    do_dynamic_expr(
      query,
      %Fragment{
        embedded?: pred_embedded?,
        arguments: [
          raw: "now()"
        ]
      },
      bindings,
      embedded?,
      type
    )
  end

  defp do_dynamic_expr(
         query,
         %Exists{at_path: at_path, path: [first | rest], expr: expr},
         bindings,
         _embedded?,
         _type
       ) do
    resource = Ash.Resource.Info.related(query.__ash_bindings__.resource, at_path)
    first_relationship = Ash.Resource.Info.relationship(resource, first)

    filter = %Ash.Filter{expression: expr, resource: first_relationship.destination}

    {:ok, source} =
      AshPostgres.Join.maybe_get_resource_query(
        first_relationship.destination,
        first_relationship,
        query
      )

    {:ok, filtered} =
      AshPostgres.DataLayer.filter(
        source,
        Ash.Filter.move_to_relationship_path(filter, rest),
        first_relationship.destination
      )

    source_ref =
      ref_binding(
        %Ref{
          attribute: Ash.Resource.Info.attribute(resource, first_relationship.source_attribute),
          relationship_path: at_path,
          resource: resource
        },
        bindings
      )

    free_binding = filtered.__ash_bindings__.current

    exists_query =
      if first_relationship.type == :many_to_many do
        through_relationship =
          Ash.Resource.Info.relationship(resource, first_relationship.join_relationship)

        through_bindings =
          query
          |> Map.delete(:__ash_bindings__)
          |> AshPostgres.DataLayer.default_bindings(
            query.__ash_bindings__.resource,
            query.__ash_bindings__.context
          )
          |> Map.get(:__ash_bindings__)
          |> Map.put(:bindings, %{
            free_binding => %{path: [], source: first_relationship.through, type: :left}
          })

        {:ok, through} =
          AshPostgres.Join.maybe_get_resource_query(
            first_relationship.through,
            through_relationship,
            query,
            [],
            through_bindings
          )

        Ecto.Query.from(destination in filtered,
          join: through in ^through,
          as: ^free_binding,
          on:
            field(through, ^first_relationship.destination_attribute_on_join_resource) ==
              field(destination, ^first_relationship.destination_attribute),
          on:
            field(parent_as(^source_ref), ^first_relationship.source_attribute) ==
              field(through, ^first_relationship.source_attribute_on_join_resource)
        )
      else
        Ecto.Query.from(destination in filtered,
          where:
            field(parent_as(^source_ref), ^first_relationship.source_attribute) ==
              field(destination, ^first_relationship.destination_attribute)
        )
      end

    exists_query = exists_query |> Ecto.Query.exclude(:select) |> Ecto.Query.select(1)

    Ecto.Query.dynamic(exists(Ecto.Query.subquery(exists_query)))
  end

  defp do_dynamic_expr(
         query,
         %Ref{attribute: %Ash.Resource.Attribute{name: name, type: attr_type}} = ref,
         bindings,
         _embedded?,
         expr_type
       ) do
    ref_binding = ref_binding(ref, bindings)

    if is_nil(ref_binding) do
      raise "Error while building reference: #{inspect(ref)}"
    end

    case AshPostgres.Types.parameterized_type(attr_type || expr_type, []) do
      nil ->
        Ecto.Query.dynamic(field(as(^ref_binding), ^name))

      type ->
        validate_type!(query, type, ref)
        Ecto.Query.dynamic(type(field(as(^ref_binding), ^name), ^type))
    end
  end

  defp do_dynamic_expr(_query, other, _bindings, true, _type) do
    if other && is_atom(other) && !is_boolean(other) do
      to_string(other)
    else
      if Ash.Filter.TemplateHelpers.expr?(other) do
        raise "Unsupported expression in AshPostgres query: #{inspect(other)}"
      else
        other
      end
    end
  end

  defp do_dynamic_expr(query, value, bindings, false, {:in, type}) when is_list(value) do
    case maybe_sanitize_list(query, value, bindings, true, type) do
      ^value ->
        validate_type!(query, type, value)
        Ecto.Query.dynamic(type(^value, ^{:array, type}))

      value ->
        Ecto.Query.dynamic([], ^value)
    end
  end

  defp do_dynamic_expr(query, value, bindings, false, type)
       when not is_nil(value) and is_atom(value) and not is_boolean(value) do
    do_dynamic_expr(query, to_string(value), bindings, false, type)
  end

  defp do_dynamic_expr(query, value, bindings, false, type) when type == nil or type == :any do
    maybe_sanitize_list(query, value, bindings, true, type)
  end

  defp do_dynamic_expr(query, value, bindings, false, type) do
    if Ash.Filter.TemplateHelpers.expr?(value) do
      raise "Unsupported expression in AshPostgres query: #{inspect(value)}"
    else
      case maybe_sanitize_list(query, value, bindings, true, type) do
        ^value ->
          type = AshPostgres.Types.parameterized_type(type, [])
          validate_type!(query, type, value)

          Ecto.Query.dynamic(type(^value, ^type))

        value ->
          value
      end
    end
  end

  defp maybe_uuid_to_binary({:array, type}, value, _original_value) when is_list(value) do
    Enum.map(value, &maybe_uuid_to_binary(type, &1, &1))
  end

  defp maybe_uuid_to_binary(type, value, original_value)
       when type in [
              Ash.Type.UUID.EctoType,
              :uuid
            ] and is_binary(value) do
    case Ecto.UUID.dump(value) do
      {:ok, encoded} -> encoded
      _ -> original_value
    end
  end

  defp maybe_uuid_to_binary(_type, _value, original_value), do: original_value

  defp validate_type!(query, type, context) do
    case type do
      {:parameterized, Ash.Type.CiStringWrapper.EctoType, _} ->
        require_extension!(query, "citext", context)

      :ci_string ->
        require_extension!(query, "citext", context)

      :citext ->
        require_extension!(query, "citext", context)

      _ ->
        :ok
    end
  end

  defp maybe_type(dynamic, nil, _query), do: dynamic

  defp maybe_type(dynamic, type, query) do
    type = AshPostgres.Types.parameterized_type(type, [])
    validate_type!(query, type, type)

    Ecto.Query.dynamic(type(^dynamic, ^type))
  end

  defp maybe_sanitize_list(query, value, bindings, embedded?, type) do
    if is_list(value) do
      Enum.map(value, &do_dynamic_expr(query, &1, bindings, embedded?, type))
    else
      value
    end
  end

  defp ref_binding(
         %{attribute: %Ash.Query.Aggregate{name: name}, relationship_path: []},
         bindings
       ) do
    Enum.find_value(bindings.bindings, fn {binding, data} ->
      data.type == :aggregate &&
        Enum.any?(data.aggregates, &(&1.name == name)) && binding
    end)
  end

  defp ref_binding(%{attribute: %Ash.Resource.Attribute{}} = ref, bindings) do
    Enum.find_value(bindings.bindings, fn {binding, data} ->
      data.path == ref.relationship_path && data.type in [:inner, :left, :root] && binding
    end)
  end

  defp ref_binding(%{attribute: %Ash.Query.Aggregate{}} = ref, bindings) do
    Enum.find_value(bindings.bindings, fn {binding, data} ->
      data.path == ref.relationship_path && data.type in [:inner, :left, :root] && binding
    end)
    |> case do
      nil -> nil
      binding -> binding + 1
    end
  end

  defp do_get_path(
         query,
         %GetPath{arguments: [left, right], embedded?: pred_embedded?} = get_expr,
         bindings,
         embedded?,
         type \\ nil
       ) do
    path = Enum.map(right, &to_string/1)

    expr =
      do_dynamic_expr(
        query,
        %Fragment{
          embedded?: pred_embedded?,
          arguments: [
            raw: "(",
            expr: left,
            raw: " #>> ",
            expr: path,
            raw: ")"
          ]
        },
        bindings,
        embedded?,
        type
      )

    if type do
      # If we know a type here we use it, since we're pulling out text
      validate_type!(query, type, get_expr)
      Ecto.Query.dynamic(type(^expr, ^type))
    else
      expr
    end
  end

  defp require_ash_functions!(query) do
    installed_extensions =
      AshPostgres.DataLayer.Info.repo(query.__ash_bindings__.resource).installed_extensions()

    unless "ash-functions" in installed_extensions do
      raise """
      Cannot use `||` or `&&` operators without adding the extension `ash-functions` to your repo.

      Add it to the list in `installed_extensions/0`

      If you are using the migration generator, you will then need to generate migrations.
      If not, you will need to copy the following into a migration:

      execute(\"\"\"
      CREATE OR REPLACE FUNCTION ash_elixir_or(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
      AS $$ SELECT COALESCE(NULLIF($1, FALSE), $2) $$
      LANGUAGE SQL;
      \"\"\")

      execute(\"\"\"
      CREATE OR REPLACE FUNCTION ash_elixir_or(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE)
      AS $$ SELECT COALESCE($1, $2) $$
      LANGUAGE SQL;
      \"\"\")

      execute(\"\"\"
      CREATE OR REPLACE FUNCTION ash_elixir_and(left BOOLEAN, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
        SELECT CASE
          WHEN $1 IS TRUE THEN $2
          ELSE $1
        END $$
      LANGUAGE SQL;
      \"\"\")

      execute(\"\"\"
      CREATE OR REPLACE FUNCTION ash_elixir_and(left ANYCOMPATIBLE, in right ANYCOMPATIBLE, out f1 ANYCOMPATIBLE) AS $$
        SELECT CASE
          WHEN $1 IS NOT NULL THEN $2
          ELSE $1
        END $$
      LANGUAGE SQL;
      \"\"\")
      """
    end
  end

  defp require_extension!(query, extension, context) do
    repo = AshPostgres.DataLayer.Info.repo(query.__ash_bindings__.resource)

    unless extension in repo.installed_extensions() do
      raise Ash.Error.Query.InvalidExpression,
        expression: context,
        message:
          "The #{extension} extension needs to be installed before #{inspect(context)} can be used. Please add \"#{extension}\" to the list of installed_extensions in #{inspect(repo)}."
    end
  end

  defp float_type?({:parameterized, type, params}) when is_atom(type) do
    type.type(params) in [:float, :decimal]
  end

  defp float_type?(_) do
    false
  end

  defp determine_type_at_path(type, path) do
    path
    |> Enum.reject(&is_integer/1)
    |> do_determine_type_at_path(type)
    |> case do
      nil ->
        nil

      {type, constraints} ->
        AshPostgres.Types.parameterized_type(type, constraints)
    end
  end

  defp do_determine_type_at_path([], _), do: nil

  defp do_determine_type_at_path([item], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}, constraints: constraints} ->
        constraints = constraints[:items] || []

        {type, constraints}

      %{type: type, constraints: constraints} ->
        {type, constraints}
    end
  end

  defp do_determine_type_at_path([item | rest], type) do
    case Ash.Resource.Info.attribute(type, item) do
      nil ->
        nil

      %{type: {:array, type}} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end

      %{type: type} ->
        if Ash.Type.embedded_type?(type) do
          type
        else
          nil
        end
    end
    |> case do
      nil ->
        nil

      type ->
        do_determine_type_at_path(rest, type)
    end
  end
end
