defmodule SelectoDBPostgreSQL.Adapter do
  @moduledoc """
  PostgreSQL adapter for Selecto.
  """

  @behaviour Selecto.DB.Adapter

  @impl true
  def name, do: :postgresql

  @impl true
  def connect({:pool, _} = pool_ref), do: {:ok, pool_ref}
  def connect(connection) when is_pid(connection) or is_atom(connection), do: {:ok, connection}
  def connect(opts) when is_map(opts), do: connect(Map.to_list(opts))

  def connect(opts) when is_list(opts) do
    with {:ok, _started_apps} <- Application.ensure_all_started(:postgrex),
         {:ok, conn} <- Postgrex.start_link(opts) do
      {:ok, conn}
    end
  end

  def connect(other), do: {:error, {:invalid_connection_options, other}}

  @impl true
  def execute({:pool, pool_ref}, query, params, opts) do
    case Selecto.ConnectionPool.execute(pool_ref, normalize_query(query), params, opts) do
      {:ok, result} -> {:ok, normalize_result(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(connection, query, params, opts) when is_pid(connection) or is_atom(connection) do
    case Postgrex.query(connection, normalize_query(query), params, opts) do
      {:ok, result} -> {:ok, normalize_result(result)}
      {:error, reason} -> {:error, reason}
    end
  end

  def execute(connection, _query, _params, _opts), do: {:error, {:invalid_connection, connection}}

  @impl true
  def execute_pool(pool_ref, query, params, opts) do
    use_prepared = Keyword.get(opts, :prepared, true)
    cache_key = if use_prepared, do: Selecto.ConnectionPool.generate_cache_key(query), else: nil

    case Selecto.ConnectionPool.get_pool_pid(pool_ref) do
      {:ok, pool_pid} ->
        execute_with_pool_pid(pool_pid, query, params, cache_key, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def execute_raw(connection, query, params) do
    cond do
      repo_module?(connection) ->
        case Kernel.apply(Ecto.Adapters.SQL, :query, [connection, normalize_query(query), params]) do
          {:ok, result} -> {:ok, normalize_result(result)}
          {:error, reason} -> {:error, Selecto.Error.from_reason(reason)}
        end

      match?({:pool, _}, connection) ->
        case execute(connection, query, params, prepared: false) do
          {:ok, result} -> {:ok, result}
          {:error, reason} -> {:error, Selecto.Error.from_reason(reason)}
        end

      is_pid(connection) or (is_atom(connection) and not is_nil(connection)) ->
        case Postgrex.query(connection, normalize_query(query), params) do
          {:ok, result} -> {:ok, normalize_result(result)}
          {:error, reason} -> {:error, Selecto.Error.from_reason(reason)}
        end

      true ->
        {:error,
         Selecto.Error.connection_error("Invalid connection type", %{
           connection: inspect(connection)
         })}
    end
  rescue
    e ->
      {:error, Selecto.Error.from_reason(e)}
  end

  @impl true
  def placeholder(index), do: ["$", Integer.to_string(index)]

  @impl true
  def quote_identifier(identifier) when is_binary(identifier) do
    escaped = String.replace(identifier, "\"", "\"\"")
    "\"#{escaped}\""
  end

  def quote_identifier(identifier), do: identifier |> to_string() |> quote_identifier()

  @impl true
  def supports?(feature) do
    feature in [
      :cte,
      :jsonb,
      :array_ops,
      :array_any_comparison,
      :native_null_ordering,
      :rollup,
      :returning,
      :text_search,
      :window_functions,
      :lateral_join,
      :prefix,
      :stream,
      :schema_introspection,
      :materialized_view_refresh,
      :materialized_view_refresh_concurrently
    ]
  end

  @impl true
  def refresh_materialized_view(connection, database_name, opts \\ []) do
    query =
      Selecto.ViewPublisher.refresh_sql(database_name,
        concurrently: Keyword.get(opts, :concurrently, false)
      )

    case introspection_query(connection, query, []) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_tables(connection, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")

    query = """
    SELECT table_name
    FROM information_schema.tables
    WHERE table_schema = $1
      AND table_type = 'BASE TABLE'
    ORDER BY table_name
    """

    case introspection_query(connection, query, [schema]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [table_name] -> table_name end)}
      {:error, reason} -> {:error, {:query_failed, reason}}
    end
  end

  @impl true
  def list_relations(connection, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    include_views = Keyword.get(opts, :include_views, false)

    query =
      if include_views do
        """
        SELECT table_name,
               CASE table_type
                 WHEN 'BASE TABLE' THEN 'table'
                 WHEN 'VIEW' THEN 'view'
               END AS source_kind
        FROM information_schema.tables
        WHERE table_schema = $1
          AND table_type IN ('BASE TABLE', 'VIEW')
        UNION ALL
        SELECT matviewname AS table_name,
               'materialized_view' AS source_kind
        FROM pg_matviews
        WHERE schemaname = $1
        ORDER BY table_name
        """
      else
        """
        SELECT table_name, 'table' AS source_kind
        FROM information_schema.tables
        WHERE table_schema = $1
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """
      end

    case introspection_query(connection, query, [schema]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [table_name, source_kind] ->
           %{name: table_name, source_kind: normalize_relation_source_kind(source_kind)}
         end)}

      {:error, reason} ->
        {:error, {:query_failed, reason}}
    end
  end

  @impl true
  def introspect_table(connection, table_name, opts \\ []) do
    schema = Keyword.get(opts, :schema, "public")
    include_associations = Keyword.get(opts, :include_associations, true)
    expand = Keyword.get(opts, :expand, false)

    with {:ok, columns} <- get_columns(connection, table_name, schema),
         {:ok, primary_key} <- get_primary_key(connection, table_name, schema),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table_name, schema) do
      fields = Enum.map(columns, & &1.column_name)

      field_types =
        Enum.into(columns, %{}, fn column ->
          {column.column_name, map_pg_type(connection, column.data_type, column.udt_name)}
        end)

      associations =
        cond do
          not include_associations ->
            %{}

          expand ->
            case build_expanded_associations(connection, table_name, schema, primary_key) do
              {:ok, expanded_associations} -> expanded_associations
              {:error, _reason} -> build_associations(foreign_keys)
            end

          true ->
            build_associations(foreign_keys)
        end

      column_metadata =
        Enum.into(columns, %{}, fn column ->
          {column.column_name,
           %{
             type: Map.get(field_types, column.column_name),
             nullable: column.is_nullable == "YES",
             default: column.column_default,
             max_length: column.character_maximum_length,
             precision: column.numeric_precision,
             scale: column.numeric_scale
           }}
        end)

      {:ok,
       %{
         table_name: table_name,
         schema: schema,
         fields: fields,
         field_types: field_types,
         primary_key: primary_key,
         associations: associations,
         columns: column_metadata,
         source: :postgresql
       }}
    end
  end

  @impl true
  def rollup_literal_order(index), do: [Integer.to_string(index), " asc nulls first"]

  @impl true
  def rollup_sort_fix(connection) do
    case server_version_major(connection) do
      {:ok, major} when is_integer(major) and major >= 18 -> false
      _ -> true
    end
  end

  @impl true
  def stream({:pool, pool_ref}, query, params, opts) do
    case resolve_stream_pool_connection(pool_ref) do
      {:ok, pool_conn} -> {:ok, build_postgrex_cursor_stream(pool_conn, query, params, opts)}
      {:error, details} -> {:error, {:invalid_stream_pool, details}}
    end
  end

  def stream(conn, query, params, opts) when is_pid(conn) or is_atom(conn) do
    {:ok, build_postgrex_cursor_stream(conn, query, params, opts)}
  end

  def stream(connection, _query, _params, _opts) do
    {:error, {:invalid_connection, connection}}
  end

  @server_version_num_query "show server_version_num"

  @impl true
  def server_version_major(connection) do
    with {:ok, version_num} <- fetch_server_version_num(connection),
         true <- is_integer(version_num) and version_num > 0 do
      {:ok, div(version_num, 10_000)}
    else
      false -> {:error, :invalid_server_version_num}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_server_version_num}
    end
  end

  @impl true
  def validate_connection(connection) do
    cond do
      repo_module?(connection) ->
        :ok

      is_atom(connection) and not is_nil(connection) ->
        :ok

      match?({:pool, _}, connection) ->
        validate_pool_connection(connection)

      is_pid(connection) ->
        if Process.alive?(connection),
          do: :ok,
          else: {:error, "Postgrex connection process is not alive"}

      true ->
        {:error, "Invalid connection configuration"}
    end
  end

  @impl true
  def connection_info(connection) do
    cond do
      repo_module?(connection) ->
        %{type: :ecto_repo, repo: connection, status: :connected}

      is_atom(connection) and not is_nil(connection) ->
        %{type: :postgrex, pid: connection, status: :connected}

      match?({:pool, _}, connection) ->
        %{
          type: :connection_pool,
          pool_ref: elem(connection, 1),
          status: :connected,
          pool_stats: pool_stats(connection)
        }

      is_pid(connection) ->
        %{
          type: :postgrex,
          pid: connection,
          status: if(Process.alive?(connection), do: :connected, else: :disconnected)
        }

      true ->
        %{type: :unknown, value: connection, status: :invalid}
    end
  end

  @impl true
  def with_connection(pool_ref, fun) when is_function(fun, 1) do
    case Selecto.ConnectionPool.get_pool_pid(pool_ref) do
      {:ok, pool_pid} ->
        try do
          result = fun.(pool_pid)
          {:ok, result}
        rescue
          e in DBConnection.ConnectionError ->
            {:error, Selecto.Error.connection_error(Exception.message(e), %{exception: e})}

          e ->
            {:error, Selecto.Error.query_error(Exception.message(e), nil, [], %{exception: e})}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def transaction(pool_ref, fun, opts \\ []) when is_function(fun, 1) do
    case Selecto.ConnectionPool.get_pool_pid(pool_ref) do
      {:ok, pool_pid} ->
        Postgrex.transaction(pool_pid, fun, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_relation_source_kind("table"), do: :table
  defp normalize_relation_source_kind("view"), do: :view
  defp normalize_relation_source_kind("materialized_view"), do: :materialized_view
  defp normalize_relation_source_kind(other), do: other

  @impl true
  def execute_repo_fallback(repo, query, params) do
    config = apply(repo, :config, [])

    postgrex_opts =
      config
      |> Keyword.take([
        :username,
        :password,
        :hostname,
        :database,
        :port,
        :socket,
        :socket_dir,
        :parameters,
        :ssl,
        :ssl_opts,
        :types,
        :timeout,
        :connect_timeout,
        :prepare,
        :queue_target,
        :queue_interval,
        :backoff_type,
        :backoff_min,
        :backoff_max,
        :idle_interval,
        :sslmode,
        :cacertfile,
        :certfile,
        :keyfile
      ])
      |> Keyword.put_new(:hostname, "localhost")
      |> Keyword.put_new(:port, 5432)
      |> Keyword.put(:supervisor, false)

    case Postgrex.start_link(postgrex_opts) do
      {:ok, conn} ->
        result = execute(conn, query, params, [])
        GenServer.stop(conn)
        result

      {:error, reason} ->
        {:error,
         Selecto.Error.connection_error("Failed to connect to database", %{reason: reason})}
    end
  end

  @impl true
  def start_pool(connection_config, pool_config, pool_name) do
    case Selecto.ConnectionPool.get_manager_pid_by_name(pool_name) do
      {:ok, manager_pid} ->
        Selecto.ConnectionPool.build_pool_ref_from_manager(manager_pid)

      :error ->
        dbconnection_opts = [
          name: pool_name,
          pool: DBConnection.ConnectionPool,
          pool_size: pool_config[:pool_size],
          pool_overflow: pool_config[:max_overflow],
          timeout: pool_config[:connection_timeout],
          queue_target: pool_config[:checkout_timeout],
          queue_interval: 1000
        ]

        postgrex_opts = Keyword.merge(connection_config, dbconnection_opts)

        case start_postgrex_connection(postgrex_opts) do
          {:ok, pool_pid, started_new_pool?} ->
            manager_opts = [
              adapter: __MODULE__,
              pool_pid: pool_pid,
              pool_name: pool_name,
              pool_config: pool_config,
              connection_config: connection_config
            ]

            case Selecto.ConnectionPool.start_manager(manager_opts) do
              {:ok, manager_pid, :started} ->
                Selecto.ConnectionPool.build_pool_ref_from_manager(manager_pid)

              {:ok, manager_pid, :existing} ->
                if started_new_pool?, do: GenServer.stop(pool_pid)
                Selecto.ConnectionPool.build_pool_ref_from_manager(manager_pid)

              {:error, reason} ->
                if started_new_pool?, do: GenServer.stop(pool_pid)
                {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp normalize_query(query) when is_binary(query), do: query
  defp normalize_query(query), do: IO.iodata_to_binary(query)

  defp introspection_query(connection, query, params) do
    case connection do
      %{query_fun: query_fun} when is_function(query_fun, 3) ->
        query_fun.(query, params, prepared: false)

      _ ->
        execute(connection, query, params, prepared: false)
    end
  end

  defp get_columns(connection, table_name, schema) do
    query = """
    SELECT
      column_name,
      data_type,
      udt_name,
      is_nullable,
      column_default,
      character_maximum_length,
      numeric_precision,
      numeric_scale,
      ordinal_position
    FROM information_schema.columns
    WHERE table_schema = $1 AND table_name = $2
    ORDER BY ordinal_position
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             column_name,
                             data_type,
                             udt_name,
                             is_nullable,
                             column_default,
                             max_length,
                             precision,
                             scale,
                             _ordinal_position
                           ] ->
           %{
             column_name: String.to_atom(column_name),
             data_type: data_type,
             udt_name: udt_name,
             is_nullable: is_nullable,
             column_default: column_default,
             character_maximum_length: max_length,
             numeric_precision: precision,
             numeric_scale: scale
           }
         end)}

      {:error, reason} ->
        {:error, {:columns_query_failed, reason}}
    end
  end

  defp get_primary_key(connection, table_name, schema) do
    query = """
    SELECT a.attname
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid
      AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = ($1 || '.' || $2)::regclass
      AND i.indisprimary
    ORDER BY a.attnum
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: []}} -> {:ok, nil}
      {:ok, %{rows: [[single_key]]}} -> {:ok, String.to_atom(single_key)}
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [key] -> String.to_atom(key) end)}
      {:error, reason} -> {:error, {:primary_key_query_failed, reason}}
    end
  end

  defp get_foreign_keys(connection, table_name, schema) do
    query = """
    SELECT
      tc.constraint_name,
      kcu.column_name,
      ccu.table_schema AS foreign_table_schema,
      ccu.table_name AS foreign_table_name,
      ccu.column_name AS foreign_column_name
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND tc.table_schema = $1
      AND tc.table_name = $2
    ORDER BY tc.constraint_name, kcu.ordinal_position
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             constraint_name,
                             column_name,
                             foreign_schema,
                             foreign_table,
                             foreign_col
                           ] ->
           %{
             constraint_name: constraint_name,
             column_name: String.to_atom(column_name),
             foreign_table_schema: foreign_schema,
             foreign_table_name: foreign_table,
             foreign_column_name: String.to_atom(foreign_col)
           }
         end)}

      {:error, reason} ->
        {:error, {:foreign_keys_query_failed, reason}}
    end
  end

  defp get_reverse_foreign_keys(connection, table_name, schema) do
    query = """
    SELECT
      tc.table_name AS referencing_table,
      kcu.column_name AS referencing_column,
      ccu.column_name AS referenced_column,
      tc.constraint_name
    FROM information_schema.table_constraints AS tc
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
    WHERE tc.constraint_type = 'FOREIGN KEY'
      AND ccu.table_schema = $1
      AND ccu.table_name = $2
    ORDER BY tc.table_name, tc.constraint_name, kcu.ordinal_position
    """

    case introspection_query(connection, query, [schema, table_name]) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             referencing_table,
                             referencing_column,
                             referenced_column,
                             constraint_name
                           ] ->
           %{
             referencing_table: referencing_table,
             referencing_column: String.to_atom(referencing_column),
             referenced_column: String.to_atom(referenced_column),
             constraint_name: constraint_name
           }
         end)}

      {:error, reason} ->
        {:error, {:reverse_foreign_keys_query_failed, reason}}
    end
  end

  defp build_associations(foreign_keys) do
    Enum.into(foreign_keys, %{}, fn foreign_key ->
      association_name =
        foreign_key.column_name
        |> Atom.to_string()
        |> String.replace_suffix("_id", "")
        |> String.to_atom()

      related_module_name = table_name_to_module(foreign_key.foreign_table_name)

      {association_name,
       %{
         type: :belongs_to,
         association_type: :belongs_to,
         related_schema: related_module_name,
         related_module_name: related_module_name,
         related_table: foreign_key.foreign_table_name,
         queryable: String.to_atom(foreign_key.foreign_table_name),
         field: association_name,
         owner_key: foreign_key.column_name,
         related_key: foreign_key.foreign_column_name,
         join_type: :inner,
         is_through: false,
         constraint_name: foreign_key.constraint_name
       }}
    end)
  end

  defp build_expanded_associations(connection, table_name, schema, primary_key) do
    with {:ok, foreign_keys} <- get_foreign_keys(connection, table_name, schema),
         {:ok, reverse_foreign_keys} <- get_reverse_foreign_keys(connection, table_name, schema),
         {:ok, junction_tables} <- detect_junction_tables(connection, schema) do
      belongs_to = build_associations(foreign_keys)

      primary_key_field = normalize_primary_key(primary_key)

      has_many =
        Enum.into(reverse_foreign_keys, %{}, fn reverse_foreign_key ->
          association_name = String.to_atom(reverse_foreign_key.referencing_table)
          related_module_name = table_name_to_module(reverse_foreign_key.referencing_table)

          {association_name,
           %{
             type: :has_many,
             association_type: :has_many,
             related_schema: related_module_name,
             related_module_name: related_module_name,
             related_table: reverse_foreign_key.referencing_table,
             queryable: String.to_atom(reverse_foreign_key.referencing_table),
             field: association_name,
             owner_key: primary_key_field,
             related_key: reverse_foreign_key.referencing_column,
             join_type: :left,
             is_through: false,
             constraint_name: reverse_foreign_key.constraint_name
           }}
        end)

      many_to_many =
        junction_tables
        |> Enum.filter(fn junction -> table_name in junction.tables end)
        |> Enum.flat_map(fn junction ->
          {this_foreign_keys, other_foreign_keys} =
            Enum.split_with(junction.foreign_keys, fn foreign_key ->
              foreign_key.foreign_table_name == table_name
            end)

          Enum.map(other_foreign_keys, fn other_foreign_key ->
            association_name = String.to_atom(other_foreign_key.foreign_table_name)
            related_module_name = table_name_to_module(other_foreign_key.foreign_table_name)

            owner_foreign_key =
              case this_foreign_keys do
                [foreign_key | _] -> foreign_key.column_name
                _ -> primary_key_field
              end

            {association_name,
             %{
               type: :many_to_many,
               association_type: :many_to_many,
               related_schema: related_module_name,
               related_module_name: related_module_name,
               related_table: other_foreign_key.foreign_table_name,
               queryable: String.to_atom(other_foreign_key.foreign_table_name),
               field: association_name,
               owner_key: primary_key_field,
               related_key: other_foreign_key.foreign_column_name,
               join_type: :left,
               is_through: false,
               join_through: junction.table,
               join_keys: [
                 {owner_foreign_key, primary_key_field},
                 {other_foreign_key.column_name, other_foreign_key.foreign_column_name}
               ]
             }}
          end)
        end)
        |> Enum.into(%{})

      {:ok, belongs_to |> Map.merge(has_many) |> Map.merge(many_to_many)}
    end
  end

  defp detect_junction_tables(connection, schema) do
    with {:ok, tables} <- list_tables(connection, schema: schema) do
      junction_tables =
        Enum.flat_map(tables, fn table ->
          case analyze_junction_table(connection, table, schema) do
            {:ok, junction_table} -> [junction_table]
            _ -> []
          end
        end)

      {:ok, junction_tables}
    end
  end

  defp analyze_junction_table(connection, table, schema) do
    with {:ok, columns} <- get_columns(connection, table, schema),
         {:ok, foreign_keys} <- get_foreign_keys(connection, table, schema),
         {:ok, primary_key} <- get_primary_key(connection, table, schema),
         true <- junction_table?(columns, foreign_keys) do
      primary_key_fields = normalize_primary_keys(primary_key)
      foreign_key_fields = Enum.map(foreign_keys, & &1.column_name)
      all_fields = Enum.map(columns, & &1.column_name)

      {:ok,
       %{
         table: table,
         foreign_keys: foreign_keys,
         primary_key: primary_key,
         extra_columns: all_fields -- Enum.uniq(primary_key_fields ++ foreign_key_fields),
         tables: Enum.map(foreign_keys, & &1.foreign_table_name)
       }}
    else
      false -> {:error, :not_junction_table}
      {:error, reason} -> {:error, reason}
    end
  end

  defp junction_table?(columns, foreign_keys) do
    foreign_key_fields = MapSet.new(Enum.map(foreign_keys, & &1.column_name))

    data_fields =
      columns
      |> Enum.map(& &1.column_name)
      |> Enum.reject(fn field ->
        field_name = Atom.to_string(field)

        field_name in ["id", "inserted_at", "updated_at", "created_at"] or
          String.ends_with?(field_name, "_at")
      end)

    length(foreign_keys) == 2 and Enum.all?(data_fields, &MapSet.member?(foreign_key_fields, &1))
  end

  defp normalize_primary_key([primary_key | _]), do: primary_key
  defp normalize_primary_key(primary_key) when is_atom(primary_key), do: primary_key
  defp normalize_primary_key(_), do: :id

  defp normalize_primary_keys(primary_key) when is_list(primary_key), do: primary_key
  defp normalize_primary_keys(primary_key) when is_atom(primary_key), do: [primary_key]
  defp normalize_primary_keys(_), do: []

  defp map_pg_type(connection, data_type, udt_name) do
    case {data_type, udt_name} do
      {"smallint", _} ->
        :integer

      {"integer", _} ->
        :integer

      {"bigint", _} ->
        :integer

      {"smallserial", _} ->
        :integer

      {"serial", _} ->
        :integer

      {"bigserial", _} ->
        :integer

      {"numeric", _} ->
        :decimal

      {"decimal", _} ->
        :decimal

      {"real", _} ->
        :float

      {"double precision", _} ->
        :float

      {"character varying", _} ->
        :string

      {"character", _} ->
        :string

      {"text", _} ->
        :string

      {"citext", _} ->
        :string

      {"boolean", _} ->
        :boolean

      {"date", _} ->
        :date

      {"time without time zone", _} ->
        :time

      {"time with time zone", _} ->
        :time

      {"timestamp without time zone", _} ->
        :naive_datetime

      {"timestamp with time zone", _} ->
        :utc_datetime

      {"json", _} ->
        :jsonb

      {"jsonb", _} ->
        :jsonb

      {"uuid", _} ->
        :binary_id

      {"ARRAY", udt} ->
        {:array, map_pg_type(connection, base_data_type_for_array(udt), normalize_array_udt(udt))}

      {"USER-DEFINED", udt} ->
        map_user_defined_type(connection, udt)

      _ ->
        map_udt_fallback(connection, data_type, udt_name)
    end
  end

  defp map_udt_fallback(connection, _data_type, udt_name) when is_binary(udt_name) do
    case map_user_defined_type(connection, udt_name) do
      :string -> :string
    end
  end

  defp map_udt_fallback(_connection, _data_type, _udt_name), do: :string

  defp map_user_defined_type(connection, udt_name) do
    case get_enum_values(connection, udt_name) do
      {:ok, [_ | _]} -> :string
      _ -> :string
    end
  end

  defp get_enum_values(connection, enum_type_name) do
    query = """
    SELECT e.enumlabel
    FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    WHERE t.typname = $1
    ORDER BY e.enumsortorder
    """

    case introspection_query(connection, query, [enum_type_name]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [label] -> label end)}
      {:error, reason} -> {:error, {:enum_values_query_failed, reason}}
    end
  end

  defp base_data_type_for_array(<<base::binary>>) do
    case normalize_array_udt(base) do
      "int2" -> "smallint"
      "int4" -> "integer"
      "int8" -> "bigint"
      "varchar" -> "character varying"
      "text" -> "text"
      "bool" -> "boolean"
      "uuid" -> "uuid"
      "jsonb" -> "jsonb"
      "json" -> "json"
      "numeric" -> "numeric"
      "date" -> "date"
      "timestamp" -> "timestamp without time zone"
      "timestamptz" -> "timestamp with time zone"
      _ -> "USER-DEFINED"
    end
  end

  defp normalize_array_udt("_" <> base), do: base
  defp normalize_array_udt(base), do: base

  defp table_name_to_module(table_name) when is_binary(table_name) do
    table_name
    |> singularize()
    |> Macro.camelize()
  end

  defp singularize(word) do
    cond do
      String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      String.ends_with?(word, "sses") ->
        String.replace_suffix(word, "sses", "ss")

      String.ends_with?(word, "ses") ->
        String.replace_suffix(word, "ses", "s")

      String.ends_with?(word, "s") and not String.ends_with?(word, "ss") ->
        String.replace_suffix(word, "s", "")

      true ->
        word
    end
  end

  defp validate_pool_connection({:pool, pool_ref}) do
    try do
      case Selecto.ConnectionPool.pool_stats(pool_ref) do
        %{error: _} -> {:error, "Connection pool is not available"}
        stats when is_map(stats) -> :ok
      end
    catch
      :exit, _ -> {:error, "Connection pool is not available"}
    end
  end

  defp pool_stats({:pool, pool_ref}) do
    try do
      Selecto.ConnectionPool.pool_stats(pool_ref)
    catch
      :exit, _ -> %{error: "Pool manager not available"}
    end
  end

  defp execute_with_pool_pid(pool_pid, query, params, cache_key, opts) do
    timeout = Keyword.get(opts, :timeout, 15_000)

    try do
      if cache_key do
        execute_with_prepared_cache(pool_pid, query, params, cache_key, timeout)
      else
        Postgrex.query(pool_pid, query, params, timeout: timeout)
      end
    rescue
      e in DBConnection.ConnectionError ->
        {:error, Selecto.Error.connection_error(Exception.message(e), %{exception: e})}

      e in Postgrex.Error ->
        {:error, Selecto.Error.query_error(Exception.message(e), query, params, %{exception: e})}

      e ->
        {:error, Selecto.Error.query_error(Exception.message(e), query, params, %{exception: e})}
    end
  end

  defp execute_with_prepared_cache(pool_pid, query, params, cache_key, timeout) do
    case Selecto.ConnectionPool.prepared_statement_cached?(pool_pid, cache_key) do
      false ->
        result = Postgrex.query(pool_pid, query, params, timeout: timeout)

        if match?({:ok, _}, result) do
          Selecto.ConnectionPool.mark_prepared_statement(pool_pid, cache_key)
        end

        result

      true ->
        Postgrex.query(pool_pid, query, params, timeout: timeout)
    end
  end

  defp start_postgrex_connection(postgrex_opts) do
    case Postgrex.start_link(postgrex_opts) do
      {:ok, pool_pid} -> {:ok, pool_pid, true}
      {:error, {:already_started, pool_pid}} -> {:ok, pool_pid, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_result(%{rows: rows, columns: columns}) do
    %{
      rows: rows || [],
      columns: Enum.map(columns || [], &to_string/1)
    }
  end

  defp repo_module?(connection) when is_atom(connection) do
    Code.ensure_loaded?(connection) and function_exported?(connection, :config, 0) and
      function_exported?(connection, :__adapter__, 0)
  end

  defp repo_module?(_), do: false

  defp resolve_stream_pool_connection(pool_ref) when is_pid(pool_ref) or is_atom(pool_ref) do
    {:ok, pool_ref}
  end

  defp resolve_stream_pool_connection(%{pool: pool_conn})
       when is_pid(pool_conn) or is_atom(pool_conn) do
    {:ok, pool_conn}
  end

  defp resolve_stream_pool_connection(pool_ref) do
    {:error, %{stream_context: :pool, pool_ref: inspect(pool_ref)}}
  end

  defp build_postgrex_cursor_stream(conn, query, params, opts) do
    parent = self()
    ref = make_ref()
    max_rows = Keyword.get(opts, :max_rows, 500)
    stream_timeout = Keyword.get(opts, :stream_timeout, 30_000)
    receive_timeout = Keyword.get(opts, :receive_timeout, 60_000)
    queue_timeout = Keyword.get(opts, :queue_timeout, 100)

    producer =
      Keyword.get(opts, :stream_producer, fn send_chunk ->
        Postgrex.transaction(
          conn,
          fn tx_conn ->
            tx_conn
            |> Postgrex.stream(query, params, max_rows: max_rows)
            |> Enum.each(fn %Postgrex.Result{rows: rows, columns: columns} ->
              send_chunk.(rows, columns)
            end)
          end,
          timeout: stream_timeout
        )
      end)

    Stream.resource(
      fn ->
        task =
          Selecto.TaskSupervisor.async(fn ->
            tx_result =
              producer.(fn rows, columns ->
                send(parent, {ref, {:chunk, rows, columns}})
              end)

            send(parent, {ref, {:done, tx_result}})
          end)

        %{task: task, ref: ref}
      end,
      fn state ->
        ref = state.ref

        receive do
          {^ref, {:chunk, rows, columns}} ->
            stream_rows = Enum.map(rows, &{&1, columns || []})
            {stream_rows, state}

          {^ref, {:done, {:ok, _}}} ->
            {:halt, state}

          {^ref, {:done, {:error, reason}}} ->
            raise "PostgreSQL stream transaction failed: #{inspect(reason)}"
        after
          receive_timeout ->
            raise "Timed out waiting for streamed rows after #{receive_timeout}ms"
        end
      end,
      fn state ->
        case Task.shutdown(state.task, queue_timeout) do
          nil -> :ok
          {:exit, _} -> :ok
          _ -> :ok
        end
      end
    )
  end

  defp fetch_server_version_num({:pool, pool_ref}) do
    try do
      case Selecto.ConnectionPool.execute(pool_ref, @server_version_num_query, [],
             prepared: false
           ) do
        {:ok, result} -> extract_server_version_num(result)
        {:error, _reason} = error -> error
      end
    catch
      :exit, _reason -> {:error, :pool_unavailable}
    end
  end

  defp fetch_server_version_num(connection) when is_atom(connection) do
    cond do
      function_exported?(connection, :query, 2) ->
        case apply(connection, :query, [@server_version_num_query, []]) do
          {:ok, result} -> extract_server_version_num(result)
          {:error, _reason} = error -> error
          _other -> {:error, :invalid_query_result}
        end

      is_pid(Process.whereis(connection)) ->
        fetch_server_version_num_with_postgrex(connection)

      true ->
        {:error, :unsupported_connection}
    end
  end

  defp fetch_server_version_num(connection) when is_pid(connection) do
    fetch_server_version_num_with_postgrex(connection)
  end

  defp fetch_server_version_num(connection) when is_list(connection) do
    case Postgrex.start_link(Keyword.put_new(connection, :supervisor, false)) do
      {:ok, pid} ->
        result = fetch_server_version_num_with_postgrex(pid)
        GenServer.stop(pid)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_server_version_num(connection) when is_map(connection) do
    connection
    |> Map.to_list()
    |> fetch_server_version_num()
  end

  defp fetch_server_version_num(_connection), do: {:error, :unsupported_connection}

  defp fetch_server_version_num_with_postgrex(connection) do
    case Postgrex.query(connection, @server_version_num_query, []) do
      {:ok, result} -> extract_server_version_num(result)
      {:error, _reason} = error -> error
    end
  rescue
    _ -> {:error, :query_failed}
  end

  defp extract_server_version_num(%{rows: [[value | _] | _]}) do
    parse_server_version_num(value)
  end

  defp extract_server_version_num(_result), do: {:error, :missing_server_version_num}

  defp parse_server_version_num(value) when is_integer(value), do: {:ok, value}

  defp parse_server_version_num(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, :invalid_server_version_num}
    end
  end

  defp parse_server_version_num(_value), do: {:error, :invalid_server_version_num}
end
